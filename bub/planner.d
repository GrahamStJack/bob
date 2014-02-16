/**
 * Copyright 2012-2013, Graham St Jack.
 *
 * This file is part of bub, a software build tool.
 *
 * Bub is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Bub is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Bub.  If not, see <http://www.gnu.org/licenses/>.
 */

module bub.planner;

import bub.concurrency;
import bub.parser;
import bub.support;

import std.algorithm;
import std.ascii;
import std.file;
import std.path;
import std.range;
import std.string;
import std.process;

//-------------------------------------------------------------------------
// Planner
//
// Planner reads Bubfiles, understands what they mean, builds
// a tree of packages, etc, understands what it all means, enforces rules,
// binds everything to filenames, discovers modification times, scans for
// includes, and schedules actions for processing by the worker.
//
// Also receives results of successful actions from the Worker,
// does additional scanning for includes, updates modification
// times and schedules more work.
//
// A critical feature is that scans for includes are deferred until
// a file is up-to-date.
//-------------------------------------------------------------------------

//
// Return the SysLibs implied by include/import of the specified header/module,
// or an empty array if none are implied.
//
// The libs are keyed on either a full trail to a header/module, or an ancestor
// of the trail. eg: one/two/three.h, one/two, or one.
//
SysLib[] knownSystemHeader(string header, SysLib[][string] libs) {
    string trail = header;
    while (trail != ".") {
        if (trail in libs) {
            return libs[trail];
        }
        trail = dirName(trail);
    }
    return [];
}


//
// Action - specifies how to build some files, and what they depend on
//
final class Action {
    static Action[string]       byName;
    static int                  nextNumber;
    static PriorityQueue!Action queue;

    string  name;      // the name of the action
    string  command;   // the action command-string
    int     number;    // influences build order
    File[]  inputs;    // files the action directly relies on, specified with initial depends
    File[]  builds;    // files that this action builds
    File[]  depends;   // files that the action depend on
    bool    finalised; // true if the action command has been finalised
    bool    issued;    // true if the action has been issued to a worker

    this(Origin origin, Pkg pkg, string name_, string command_, File[] builds_, File[] inputs_) {
        name     = name_;
        command  = command_;
        number   = nextNumber++;
        inputs   = inputs_;
        builds   = builds_;
        depends  = inputs_;
        errorUnless(!(name in byName), origin, "Duplicate command name=%s", name);
        byName[name] = this;

        // All the files built by this action depend on the Bubfile
        depends ~= pkg.bubfile;

        // Recognise in-project tools in the command.
        foreach (token; split(command)) {
            if (token.startsWith([buildPath("dist", "bin"), "priv"])) {
                // Find the tool
                File *tool = token in File.byPath;
                errorUnless(tool !is null, origin, "Unknown in-project tool %s", token);

                // Is the tool already involved in this action?
                bool involved;
                foreach (file; chain(builds, depends)) {
                    if (file is *tool) {
                        involved = true;
                    }
                }

                if (!involved) {
                    // Verify that these built files can refer to it.
                    foreach (file; builds) {
                        if (!is(typeof(file.parent) : Pkg) &&
                            !file.parent.allowsRefTo(origin, *tool))
                        {
                            // Add enabling reference from parent to tool
                            file.parent.addReference(origin, *tool);
                        }
                        // Add reference to tool
                        file.addReference(origin, *tool);
                    }

                    // Add the dependency.
                    depends ~= *tool;
                }
            }
        }

        // set up reverse dependencies between builds and depends
        foreach (depend; depends) {
            foreach (built; builds) {
                depend.dependedBy[built] = true;
                if (g_print_deps) say("%s depends on %s", built.path, depend.path);
            }
        }
    }

    // add an extra depend to this action, returning true if it is a new one
    bool addDependency(File depend) {
        if (issued) fatal("Cannot add a dependancy to issued action %s", this);
        if (builds.length != 1) {
            fatal("cannot add a dependency to an action that builds more than one file: %s", name);
        }
        bool added;
        if (builds[0] !in depend.dependedBy) {
            depends ~= depend;
            depend.dependedBy[builds[0]] = true;
            added = true;
            if (g_print_deps) say("%s depends on %s", builds[0].path, depend.path);
        }
        return added;
    }

    // Finalise the action command.
    // Commands can contain any number of ${varname} instances, which are
    // replaced with the content of the named variable, cross-multiplied with
    // any adjacent text.
    // Special variables are:
    //   INPUT    -> Paths of the input files.
    //   OUTPUT   -> Paths of the built files.
    //   PROJ_INC -> Paths of project include/import dirs relative to build dir.
    //   PROJ_LIB -> Paths of project library dirs relative to build dir.
    //   LIBS     -> Names of all required libraries, without lib prefix or extension.
    void finaliseCommand(string[] libs) {
        //say("finalising %s command with libs=%s", builds, libs);
        assert(!issued);
        assert(!finalised);
        finalised = true;

        // Local function to expand variables in a string.
        string resolve(string text) {
            string result;

            bool   inToken, inCurly;
            size_t anchor;
            char   prev;
            string prefix, varname, suffix;

            // Local function to finish processing a token.
            void finishToken(size_t pos) {
                suffix = text[anchor .. pos];
                size_t start = result.length;

                string[] values;
                if (varname.length) {
                    // Get the variable's values
                    if      (varname == "INPUT") {
                        foreach (file; inputs) {
                            values ~= file.path;
                        }
                    }
                    else if (varname == "OUTPUT") {
                        foreach (file; builds) {
                            values ~= file.path;
                        }
                    }
                    else if (varname == "PROJ_INC") {
                        values = ["src", "obj"];
                    }
                    else if (varname == "PROJ_LIB") {
                        values = [buildPath("dist", "lib"), "obj"];
                    }
                    else if (varname == "LIBS") {
                        values = libs;
                    }
                    else if (varname in options) {
                        values = split(resolve(options[varname]));
                    }
                    else {
                        try {
                            string value = environment[varname];
                            values = [value];
                        }
                        catch (Exception ex) {
                            values = [];
                        }
                    }

                    // Cross-multiply with prefix and suffix
                    foreach (value; values) {
                        result ~= prefix ~ value ~ suffix ~ " ";
                    }
                }
                else {
                    // No variable - just use the suffix
                    result ~= suffix ~ " ";
                }

                // Clean up for next token
                prefix  = "";
                varname = "";
                suffix  = "";
                inToken = false;
                inCurly = false;
            }

            foreach (pos, ch; text) {
                if (!inToken && !isWhite(ch)) {
                    // Starting a token
                    inToken = true;
                    anchor  = pos;
                }
                else if (inToken && ch == '{' && prev == '$') {
                    // Starting a varname within a token
                    prefix  = text[anchor .. pos-1];
                    inCurly = true;
                    anchor  = pos + 1;
                }
                else if (ch == '}') {
                    // Finished a varname within a token
                    if (!inCurly) {
                        fatal("Unmatched '}' in '%s'", text);
                    }
                    varname = text[anchor .. pos];
                    inCurly = false;
                    anchor  = pos + 1;
                }
                else if (inToken && isWhite(ch)) {
                    // Finished a token
                    finishToken(pos);
                }
                prev = ch;
            }
            if (inToken) {
                finishToken(text.length);
            }
            return result.strip();
        }

        command = resolve(command);
    }

    // issue this action
    void issue() {
        assert(!issued);
        if (!finalised) {
            finaliseCommand([]);
        }
        issued = true;
        queue.insert(this);
    }

    override string toString() {
        return name;
    }
    override int opCmp(Object o) const {
        // reverse order
        if (this is o) return 0;
        Action a = cast(Action)o;
        if (a is null) return  -1;
        return a.number - number;
    }
}


//
// Node - abstract base class for things in an ownership tree
// with cross-linked dependencies. Used to manage allowed references.
//

// additional constraint on allowed references
enum Privacy { PUBLIC,           // no additional constraint
               SEMI_PROTECTED,   // only accessable to descendents of grandparent
               PROTECTED,        // only accessible to children of parent
               PRIVATE }         // not accessible

//
// return the privacy implied by args
//
Privacy privacyOf(ref Origin origin, string[] args) {
    if (!args.length ) return Privacy.PUBLIC;
    else if (args[0] == "protected")      return Privacy.PROTECTED;
    else if (args[0] == "semi-protected") return Privacy.SEMI_PROTECTED;
    else if (args[0] == "private")        return Privacy.PRIVATE;
    else if (args[0] == "public")         return Privacy.PUBLIC;
    else error(origin, "privacy must be one of public, semi-protected, protected or private");
    assert(0);
}


class Node {
    static Node[string] byTrail;

    string  name;    // simple name this node adds to parent
    string  trail;   // slash-separated name components from after-root to this
    Node    parent;
    Privacy privacy;
    Node[]  children;
    Node[]  refers;

    override string toString() const {
        return trail;
    }

    // create the root of the tree
    this() {
        trail = "root";
        assert(trail !in byTrail, "already have root node");
        byTrail[trail] = this;
    }

    // create a node and place it into the tree
    this(Origin origin, Node parent_, string name_, Privacy privacy_) {
        assert(parent_);
        errorUnless(dirName(name_) == ".",
                    origin,
                    "Cannot define node with multi-part name '%s'", name_);
        parent  = parent_;
        name    = name_;
        privacy = privacy_;
        if (parent.parent) {
            // child of non-root
            trail = buildPath(parent.trail, name);
        }
        else {
            // child of the root
            trail = name;
        }
        parent.children ~= this;
        errorUnless(trail !in byTrail, origin, "%s already known", trail);
        byTrail[trail] = this;
    }

    // return true if this is a descendant of other
    private bool isDescendantOf(Node other) {
        for (auto node = this; node !is null; node = node.parent) {
            if (node is other) return true;
        }
        return false;
    }

    // return true if this is a visible descendant of other
    private bool isVisibleDescendantOf(Node other, Privacy allowed) {
        for (auto node = this; node !is null; node = node.parent) {
            if (node is other)            return true;
            if (node.privacy > allowed)   break;
            if (allowed > Privacy.PUBLIC) allowed--;
        }
        return false;
    }

    // return true if other is a visible-child or reference of this,
    // or is a visible-descendant of them
    bool allowsRefTo(ref Origin origin,
                     Node       other,
                     size_t     depth        = 0,
                     Privacy    allowPrivacy = Privacy.PROTECTED,
                     bool[Node] checked      = null) {
        errorUnless(depth < 100, origin,
                    "circular reference involving %s referring to %s",
                    this,
                    other);
        //say("for %s: checking if %s allowsReferenceTo %s", origin.path, this, other);
        if (other is this || other.isVisibleDescendantOf(this, allowPrivacy)) {
            if (g_print_details) say("%s allows reference to %s via containment", this, other);
            return true;
        }
        foreach (node; refers) {
            // referred-to nodes grant access to their public children, and referred-to
            // siblings grant access to their semi-protected children
            if (node !in checked) {
                checked[node] = true;
                if (node.allowsRefTo(origin,
                                     other,
                                     depth+1,
                                     node.parent is this.parent ?
                                     Privacy.SEMI_PROTECTED : Privacy.PUBLIC,
                                     checked)) {
                    if (g_print_details) {
                        say("%s allows reference to %s via explicit reference", this, other);
                    }
                    return true;
                }
            }
        }
        return false;
    }

    // Add a reference to another node. Cannot refer to:
    // * Nodes that aren't defined yet.
    // * Self.
    // * Ancestors.
    // * Nodes whose selves or ancestors have not been referred to by our parent.
    // Also can't explicitly refer to children - you get that implicitly.
    final void addReference(ref Origin origin, Node other, string cause = null) {
        errorUnless(other !is null, origin,
                    "%s cannot refer to NULL node", this);

        errorUnless(other != this, origin,
                    "%s cannot refer to self", this);

        errorUnless(!this.isDescendantOf(other), origin,
                    "%s cannot refer to ancestor %s", this, other);

        errorUnless(!other.isDescendantOf(this), origin,
                    "%s cannnot explicitly refer to descendant %s", this, other);

        errorUnless(this.parent.allowsRefTo(origin, other), origin,
                    "Parent %s does not allow %s to refer to %s", parent, this, other);

        errorUnless(!other.allowsRefTo(origin, this), origin,
                    "%s cannot refer to %s because of a circularity", this, other);

        if (g_print_deps) say("%s refers to %s%s", this, other, cause);
        refers ~= other;
    }
}


//
// Pkg - a package (directory containing a Bubfile).
// Has a Bubfile, assorted source and built files, and sub-packages
// Used to group files together for dependency control, and to house a Bubfile.
//
final class Pkg : Node {

    File bubfile;

    this(Origin origin, Node parent_, string name_, Privacy privacy_) {
        super(origin, parent_, name_, privacy_);
        bubfile = File.addSource(origin, this, "Bubfile", Privacy.PRIVATE, false);
    }
}


//
// A file
//
class File : Node {
    static File[string]   byPath;      // Files by their path
    static File[][string] byName;      // Files by their basename
    static bool[File]     allBuilt;    // all built files
    static bool[File]     outstanding; // outstanding buildable files
    static int            nextNumber;

    // Statistics
    static uint numBuilt;              // number of files targeted
    static uint numUpdated;            // number of files successfully updated by actions

    string     path;                   // the file's path
    int        number;                 // order of file creation
    bool       scannable;              // true if the file should be scanned
    bool       built;                  // true if this file will be built by an action
    Action     action;                 // the action used to build this file (null if non-built)

    long       modTime;                // the modification time of this file
    bool       used;                   // true if this file has been used already

    // state-machine stuff
    bool         scanned;                // true if this has already been scanned for includes
    Origin[File] includes;               // Origins by the Files this includes
    bool[File]   includedBy;             // Files that include this
    bool[File]   dependedBy;             // Files that depend on this
    bool         clean;                  // true if usable by higher-level files

    // return a prospective path to a potential file.
    static string prospectivePath(string start, Node parent, string extra) {
        Node node = parent;
        while (node !is null) {
            Pkg pkg = cast(Pkg) node;
            if (pkg) {
                return buildPath(start, pkg.trail, extra);
            }
            node = node.parent;
        }
        fatal("prospective file %s's parent %s has no package in its ancestry", extra, parent);
        assert(0);
    }

    this(ref Origin origin, Node parent_, string name_, Privacy privacy_, string path_,
         bool scannable_, bool built_)
    {
        super(origin, parent_, name_, privacy_);

        path      = path_;
        scannable = scannable_;
        built     = built_;

        number    = nextNumber++;

        modTime   = modifiedTime(path, built);

        errorUnless(path !in byPath, origin, "%s already defined", path);
        byPath[path] = this;
        byName[baseName(path)] ~= this;

        if (built) {
            ++numBuilt;
            allBuilt[this] = true;
            outstanding[this] = true;
        }
    }

    // Add a source file specifying its trail within its package
    static File addSource(ref Origin origin, Node parent, string extra, Privacy privacy, bool scannable) {

        // possible paths to the file
        string path1 = prospectivePath("obj", parent, extra);  // a built file in obj directory tree
        string path2 = prospectivePath("src", parent, extra);  // a source file in src directory tree

        string name  = baseName(extra);

        File * file = path1 in byPath;
        if (file) {
            // this is a built source file we already know about
            errorUnless(!file.used, origin, "%s has already been used", path1);
            return *file;
        }
        else if (exists(path2)) {
            // a source file under src
            return new File(origin, parent, name, privacy, path2, scannable, false);
        }
        else {
            error(origin, "Could not find source file %s in %s, or %s", name, path1, path2);
            assert(0);
        }
    }

    // This file has been updated
    final void updated() {
        ++numUpdated;
        modTime = modifiedTime(path, true);
        if (g_print_details) say("Updated %s, mod_time %s", this, modTime);
        if (action !is null) {
            action = null;
            outstanding.remove(this);
        }
        touch();
    }

    // Scan this file for includes/imports, incorporating them into the
    // dependency graph.
    private void scan() {
        errorUnless(!scanned, Origin(path, 1), "%s has been scanned for includes twice!", this);
        scanned = true;
        bool isD = false;
        if (scannable) {

            // scan for includes
            Include[] entries;
            switch (path.extension()) {
              case ".c":
              case ".h":
              case ".cc":
              case ".hh":
              case ".cxx":
              case ".hxx":
              case ".cpp":
              case ".hpp":
                entries = scanForIncludes(path);
                break;
              case ".d":
                entries = scanForImports(path);
                isD     = true;
                break;
              default:
                fatal("Don't know how to scan %s for includes/imports", path);
            }

            foreach (entry; entries) {
                Origin origin = Origin(this.path, entry.line);

                // try to find the included file within the project or in the known system headers

                // under src?
                File *include = buildPath("src", entry.trail) in byPath;
                if (include is null) {
                    // under obj?
                    include = buildPath("obj", entry.trail) in byPath;
                }
                if (include is null &&
                    !isD &&
                    entry.quoted &&
                    dirName(entry.trail) == ".") {
                    // Include/import is a simple name only - look for a unique filename that matches.
                    File[]* files = entry.trail in byName;
                    if (files !is null) {
                        errorUnless(files.length == 1, origin,
                                    "%s is not a unique filename", entry.trail);
                        include = &(*files)[0];
                    }
                }
                if (include is null) {
                    // Last chance - it might be a known system header or header directory.

                    SysLib[] libs = knownSystemHeader(entry.trail, SysLib.byHeader);
                    if (libs.length > 0) {
                        // known system header or system header directory -
                        // tell containers about it so they can pick up SysLibs
                        //say("included external header %s", entry.trail);
                        systemHeaderIncluded(origin, this, libs);
                        continue;
                    }
                    else if (!entry.quoted) {
                        // Ignore unknown C/C++ <system> includes, hoping they are from std libs
                        continue;
                    }
                }
                errorUnless(include !is null,
                            origin,
                            "Included/imported unknown file %s", entry.trail);
                errorUnless(include.number < this.number, origin,
                            "Included/imported file %s declared later", entry.trail);

                // Check for a circular include
                bool[File] checked;
                void checkCircularity(File other, string explanation) {
                    errorUnless(other !is this, origin,
                                "Circular include: %s", explanation);
                    if (other !in checked) {
                        foreach (next; other.includes.keys) {
                            checkCircularity(next, explanation ~ " -> " ~ next.path);
                        }
                        checked[other] = true;
                    }
                }
                checkCircularity(*include, path ~ " -> " ~ include.path);

                // Add the include
                if (g_print_deps) say("%s includes/imports %s", this.path, include.path);
                includes[*include] = origin;
                include.includedBy[this] = true;
            }
        }
    }

    // Add all the relationships implied by this file's includes.
    // IMPORTANT - called once, just before this file becomes clean,
    // which means that it is up to date and all its includes are also clean.
    // The delayed resolution is necessary because includes are discovered in
    // an arbitrary order, so we have to wait till all the down-stream includes
    // are discovered before we can work out what they mean.
    // Here are the implications of an include:
    // * Each direct or transitive include adds a dependency to this file's dependents.
    // * This file's dependents (see Binary) may infer extra things from the direct includes.
    // * Each direct include implies a reference from this to the include.
    void resolveIncludes() {

        bool[File] got;

        // Resolve consequences of transitive include
        void resolve(Origin origin, File includer, File included) {

            if (included in got) {
                return;
            }
            got[included] = true;

            // Our dependents also depend on the included file.
            foreach (dependent; dependedBy.keys()) {
                errorUnless(dependent.action !is null, origin, "%s has no action", dependent.path);
                dependent.action.addDependency(included);
            }

            // Transit into included's includes
            foreach (included2, origin2; included.includes) {
                resolve(origin2, included, included2);
            }
        }

        foreach (included, origin; includes) {
            // This file's dependents may want to know about the include too.
            includeAdded(origin, this, included);

            // Now (after includeAdded calls so this File's parents have had a chance to
            // add an enabling reference), add a reference between this file and the
            // included one.
            addReference(origin, included);

            // This file's dependents depend on this file's transitive includes.
            resolve(origin, this, included);
        }
    }

    // An include has been added from includer to included.
    // Specialisations of File override to infer linking to in-project libraries.
    void includeAdded(ref Origin origin, File includer, File included) {
        foreach (depend; dependedBy.keys()) {
            depend.includeAdded(origin, includer, included);
        }
    }

    // A system header has been included by includer (which is this or a file this depends on).
    // Specialisations of File override to infer linking to SysLibs.
    void systemHeaderIncluded(ref Origin origin, File includer, SysLib[] libs) {
        foreach (depend; dependedBy.keys()) {
            depend.systemHeaderIncluded(origin, includer, libs);
        }
    }

    // This file's action is about to be issued, and this is the last chance to
    // add dependencies to it. Specialisations should override this method, and at the
    // very least finalise the action's command.
    // Return true if dependencies were added.
    bool augmentAction() {
        if (action) {
            action.finaliseCommand([]);
        }
        return false;
    }

    // Work out if this File's state should change, and if its Action should be issued.
    final void touch() {
        if (clean) return;
        if (g_print_details) say("Touching %s", path);
        long newest;

        if (action && !action.issued) {
            // this item's action may need to be issued
            //say("file %s touched", this);

            for (;;) {
                foreach (depend; action.depends) {
                    if (!depend.clean) {
                        if (g_print_details) {
                            say("%s waiting for %s to become clean", path, depend.path);
                        }
                        return;
                    }
                    if (newest < depend.modTime) {
                        newest = depend.modTime;
                    }
                }
                // all files this one depends on are clean

                // give this file a chance to augment its action
                if (!augmentAction()) {
                    // No dependencies added - we know our newest dependency modTime
                    break;
                }

                // Dependency added - go around again to re-check dependencies
            }

            // We can issue the action now if this file is out of date
            if (modTime < newest) {
                // Out of date - issue action to worker
                if (g_print_details) {
                    say("%s is out of date with mod_time %s", this, modTime);
                }
                action.issue();
                return;
            }
            else {
                // already up to date - no need for building
                if (g_print_details) say("%s is up to date", path);
                action = null;
                outstanding.remove(this);
            }
        }

        if (action) {
            // Still waiting for action to be issued or complete
            return;
        }
        errorUnless(modTime > 0, Origin(path, 1),
                    "%s is up to date with zero mod_time!", path);
        // This file is up to date

        // If we haven't already scanned for includes, do it now.
        if (!scanned) scan();

        foreach (include; includes.keys()) {
            if (!include.clean) {
                // Can't progress until all our includes are clean
                return;
            }
        }

        // Work through all the implications of this file's includes, now that
        // all owr down-stream includes are clean.
        resolveIncludes();

        // We are now squeaky clean
        clean = true;

        // touch everything that includes or depends on this
        foreach (other; chain(includedBy.keys(), dependedBy.keys())) {
            other.touch();
        }
    }

    // Sort Files by decreasing number order. Used to determine the order
    // in which libraries are linked.
    override int opCmp(Object o) const {
        // reverse order
        if (this is o) return 0;
        File a = cast(File)o;
        if (a is null) return  -1;
        return a.number - number;
    }

    // Print a file as its path.
    override string toString() const {
        return path;
    }

}


// Free function to validate the compatibility of a source extension
// given that sourceExt is already being used.
string validateExtension(Origin origin, string newExt, string usingExt) {
    string result = usingExt;
    if (usingExt == null || usingExt == ".c") {
        result = newExt;
    }
    errorUnless(result == newExt || newExt == ".c", origin,
                "Cannot use object file compiled from %s when already using %s",
                newExt, usingExt);
    return result;
}

//
// Binary - a binary file which incorporates object files and 'owns' source files.
// Concrete implementations are StaticLib and Exe.
//
abstract class Binary : File {
    static Binary[File] byContent; // binaries by the header and body files they 'contain'

    File[]       objs;
    File[]       headers;
    bool[File]   publics;
    bool[SysLib] reqSysLibs;
    bool[Binary] reqBinaries;
    string       sourceExt;  // The source extension object files are compiled from.

    // create a binary using files from this package.
    // The sources may be already-known built files or source files in the repo,
    // but can't already be used by another Binary.
    this(ref Origin origin, Pkg pkg, string name_, string path_,
         string[] publicSources, string[] protectedSources) {

        super(origin, pkg, name_, Privacy.PUBLIC, path_, false, true);

        // Local function to add a source file to this Binary
        void addSource(string name, Privacy privacy) {

            // Create a File to represent the named source file.
            string ext = extension(name);
            File sourceFile = File.addSource(origin, this, name, privacy, isScannable(ext));

            errorUnless(sourceFile !in byContent, origin, "%s already used", sourceFile.path);
            byContent[sourceFile] = this;

            if (g_print_deps) say("%s contains %s", this.path, sourceFile.path);

            // Look for a command to do something with the source file.

            CompileCommand  *compile  = ext in compileCommands;
            GenerateCommand *generate = ext in generateCommands;

            if (compile) {
                // Compile an object file from this source.

                // Remember what source extension this binary uses.
                sourceExt = validateExtension(origin, ext, sourceExt);

                version(Posix) {
                    string destName = sourceFile.name.setExtension(".o");
                }
                version(Windows) {
                    string destName = sourceFile.name.setExtension(".obj");
                }
                string destPath = prospectivePath("obj", sourceFile.parent, destName);
                File obj = new File(origin, this, destName, Privacy.PUBLIC, destPath, false, true);
                objs ~= obj;

                errorUnless(obj !in byContent, origin, "%s already used", obj.path);
                byContent[obj] = this;

                string actionName = format("%-15s %s", "Compile", sourceFile.path);

                obj.action = new Action(origin, pkg, actionName, compile.command,
                                        [obj], [sourceFile]);
            }
            else if (generate) {
                // Generate more source files from sourceFile.

                File[] files;
                string suffixes;
                foreach (suffix; generate.suffixes) {
                    string destName = stripExtension(name) ~ suffix;
                    string destPath = buildPath("obj", parent.trail, destName);
                    File gen = new File(origin, this, destName, privacy, destPath,
                                        isScannable(suffix), true);
                    files    ~= gen;
                    suffixes ~= suffix ~ " ";
                }
                Action action = new Action(origin,
                                           pkg,
                                           format("%-15s %s", ext ~ "->" ~ suffixes, sourceFile.path),
                                           generate.command,
                                           files,
                                           [sourceFile]);
                foreach (gen; files) {
                    gen.action = action;
                }

                // And add them as sources too.
                foreach (gen; files) {
                    addSource(gen.name, privacy);
                }
            }
            else {
                // No compile or generate commands - assume it is a header file.
                headers ~= sourceFile;
            }

            if (privacy == Privacy.PUBLIC) {
                // This file may need to be exported
                publics[sourceFile] = true;
            }
        }

        errorUnless(publicSources.length + protectedSources.length > 0,
                    origin,
                    "binary must have at least one source file");

        foreach (source; publicSources) {
            addSource(source, Privacy.PUBLIC);
        }
        foreach (source; protectedSources) {
            addSource(source, Privacy.SEMI_PROTECTED);
        }
    }

    override void includeAdded(ref Origin origin, File includer, File included) {
        // A file we depend on (includer) has included another file (included).
        // This might mean that this Binary requires another (this is how we find out
        // out which libraries to link).
        Binary *includerContainer = includer in byContent;
        if (includerContainer && *includerContainer is this) {
            Binary *includedContainer = included in byContent;
            errorUnless(includedContainer !is null,
                        origin,
                        "included file is not contained in a library");
            if (*includedContainer !is this && *includedContainer !in reqBinaries) {

                // we require the container of the included file
                if (g_print_deps) say("%s requires %s", this.path, includedContainer.path);
                reqBinaries[*includedContainer] = true;

                // add a reference
                addReference(origin, *includedContainer,
                             format(" because %s includes %s", includer.path, included.path));

                // Insist that if includer is a public file in a public static lib,
                // all its includes have to also be public files in public static libs.
                // This is necessary because they all need to be copied into dist/include
                // for export.
                StaticLib slib = cast(StaticLib) *includerContainer;
                if (slib !is null && slib.isPublic && includer in slib.publics) {
                    StaticLib other = cast(StaticLib) *includedContainer;
                    errorUnless(other !is null && other.isPublic && included in other.publics,
                                origin,
                                "Exported %s cannot include non-exported %s",
                                includer,
                                included);
                }
            }
        }
    }

    override void systemHeaderIncluded(ref Origin origin, File includer, SysLib[] libs) {
        // A file we depend on (includer) has included an external header (included)
        // that isn't for one of the standard system libraries. Add the SysLib(s) to reqSysLibs.
        Binary *container = includer in byContent;
        if (container && *container is this) {
            foreach (lib; libs) {
                if (lib !in reqSysLibs) {
                    reqSysLibs[lib] = true;
                    if (g_print_deps) say("%s requires external lib '%s'", this, lib);
                }
            }
        }
    }
}


//
// StaticLib - a static library.
//
final class StaticLib : Binary {

    string uniqueName;
    bool   isPublic;

    this(ref Origin origin, Pkg pkg, string name_,
         string[] publicSources, string[] protectedSources, bool isPublic_) {

        isPublic = isPublic_;

        // Decide on a name for the library.
        uniqueName = std.array.replace(buildPath(pkg.trail, name_), dirSeparator, "-") ~ "-s";
        if (name_ == pkg.name) uniqueName = std.array.replace(pkg.trail, dirSeparator, "-") ~ "-s";
        string _basename = format("lib%s.a", uniqueName);

        // Decide on a path for the library.
        string _path;
        if (isPublic) {
            // The library is distributable.
            _path = buildPath("dist", "lib", _basename);
        }
        else {
            // The library is private to the project.
            _path = buildPath("obj", _basename);
        }

        // Super-constructor takes care of code generation and compiling to object files.
        super(origin, pkg, name_, _path, publicSources, protectedSources);

        // Decide on an action.
        string actionName = format("%-15s %s", "StaticLib", path);
        if (objs.length > 0) {
          // A proper static lib with object files
          LinkCommand *linkCommand = sourceExt in linkCommands;
          errorUnless(linkCommand && linkCommand.staticLib.length, origin,
                      "No link command for static lib from '%s'", sourceExt);
          action = new Action(origin, pkg, actionName, linkCommand.staticLib, [this], objs);

          // Add dependencies on the headers too so that includeAdded() will be called on us
          // for includes those headers make.
          foreach (header; headers) {
              action.addDependency(header);
          }
        }
        else {
          // A place-holder file to fit in with dependency tracking
          action = new Action(origin, pkg, actionName, "DUMMY", [this], headers);
        }

        if (isPublic) {
            // This library's public sources are distributable, so we copy them into dist/include
            // TODO Convert from "" to <> #includes in .h files
            string copyBase = buildPath("dist", "include");
            foreach (source; publics.keys()) {
                string destPath = prospectivePath(copyBase, this, source.name);
                File copy = new File(origin, this, source.name ~ "-copy",
                                     Privacy.PRIVATE, destPath, false, true);

                copy.action = new Action(origin, pkg,
                                         format("%-15s %s", "Export", source.path),
                                         "COPY ${INPUT} ${OUTPUT}",
                                         [copy], [source]);
            }
        }
    }
}

// Free function used by DynamicLib and Exe to determine which libraries they
// need to link with.
//
// target is the File that will use the libraries.
// binaries is all the static and system libraries known to be needed from
// source-code import/include statements.
//
// Returns the needed libraries sorted in descending number order,
// which is the appropriate order for linking.
void neededLibs(File             target,
                Binary[]         binaries,
                ref StaticLib[]  staticLibs,
                ref DynamicLib[] dynamicLibs,
                ref SysLib[]     sysLibs) {

    bool[Object] done;   // Everything already considered

    staticLibs  = [];
    dynamicLibs = [];
    sysLibs     = [];

    void accumulate(Object obj) {
        if (obj in done) return;
        done[obj] = true;

        Exe        exe  = cast(Exe)        obj;
        StaticLib  slib = cast(StaticLib)  obj;
        DynamicLib dlib = cast(DynamicLib) obj;
        SysLib     sys  = cast(SysLib)     obj;

        if (exe !is null) {
            foreach (other; exe.reqBinaries.keys) {
                accumulate(other);
            }
            foreach (other; exe.reqSysLibs.keys) {
                accumulate(other);
            }
        }
        else if (slib !is null) {
            foreach (other; slib.reqBinaries.keys) {
                accumulate(other);
            }
            foreach (other; slib.reqSysLibs.keys) {
                accumulate(other);
            }
            DynamicLib* dynamic = slib in DynamicLib.byContent;
            if (dynamic is null || dynamic.number > target.number) {
                if (slib.objs.length > 0) {
                    staticLibs ~= slib;
                }
            }
            else if (*dynamic !is target) {
                accumulate(*dynamic);
            }
        }
        else if (dlib !is null) {
            dynamicLibs ~= dlib;
        }
        else if (sys !is null) {
            sysLibs ~= sys;
        }
        else {
            fatal("logic error");
        }
    }

    foreach (obj; binaries) {
        accumulate(obj);
    }
    staticLibs.sort();
    dynamicLibs.sort();
    sysLibs.sort();

    //say("%s required libs %s,%s,%s", target, staticLibs, dynamicLibs, sysLibs);
}


//
// DynamicLib - a dynamic library. Contains all of the object files
// from a number of specified StaticLibs. If defined prior to an Exe, the Exe will
// link with the DynamicLib instead of those StaticLibs.
//
// Any StaticLibs required by the incorporated StaticLibs must also be incorporated
// into DynamicLibs.
//
// The static lib names are relative to pkg, and therefore only descendants of the DynamicLib's
// parent can be incorporated.
//
final class DynamicLib : File {
    static DynamicLib[StaticLib] byContent; // dynamic libs by the static libs they 'contain'
    Origin origin;
    string uniqueName;

    StaticLib[] staticLibs;
    string      sourceExt;

    this(ref Origin origin_, Pkg pkg, string name_, string[] staticTrails) {
        origin = origin_;

        uniqueName = std.array.replace(buildPath(pkg.trail, name_), dirSeparator, "-");
        if (name_ == pkg.name) uniqueName = std.array.replace(pkg.trail, dirSeparator, "-");
        string _path = buildPath("dist", "lib", format("lib%s.so", uniqueName));
        version(Windows) {
            _path = _path.setExtension(".dll");
        }

        super(origin, pkg, name_ ~ "-dynamic", Privacy.PUBLIC, _path, false, true);

        foreach (trail; staticTrails) {
            string trail1 = buildPath(pkg.trail, trail, baseName(trail));
            string trail2 = buildPath(pkg.trail, trail);
            Node* node = trail1 in Node.byTrail;
            if (node is null || cast(StaticLib*) node is null) {
                node = trail2 in Node.byTrail;
                if (node is null || cast(StaticLib*) node is null) {
                    error(origin,
                          "Unknown static-lib %s, looked for with trails %s and %s",
                          trail, trail1, trail2);
                }
            }
            StaticLib* staticLib = cast(StaticLib*) node;
            errorUnless(*staticLib !in byContent, origin,
                        "static lib %s already used by dynamic lib %s",
                        *staticLib, byContent[*staticLib]);
            addReference(origin, *staticLib);
            staticLibs ~= *staticLib;
            byContent[*staticLib] = this;

            sourceExt = validateExtension(origin, staticLib.sourceExt, sourceExt);
        }
        errorUnless(staticLibs.length > 0, origin, "dynamic-lib must have at least one static-lib");

        // action
        string actionName = format("%-15s %s", "DynamicLib", path);
        LinkCommand *linkCommand = sourceExt in linkCommands;
        errorUnless(linkCommand !is null && linkCommand.dynamicLib != null, origin,
                    "No link command for %s -> .dlib", sourceExt);
        File[] objs;
        foreach (staticLib; staticLibs) {
            foreach (obj; staticLib.objs) {
                objs ~= obj;
            }
        }
        action = new Action(origin, pkg, actionName, linkCommand.dynamicLib, [this], objs);
    }


    // Called just before our action is issued.
    // Verify that all the StaticLibs we now know that we depend on are contained by this or
    // another earlier-defined-than-this DynamicLib.
    // Add any required SysLibs to our action.
    override bool augmentAction() {
        StaticLib[]  neededStaticLibs;
        DynamicLib[] neededDynamicLibs;
        SysLib[]     neededSysLibs;

        neededLibs(this, cast(Binary[]) staticLibs,
                   neededStaticLibs, neededDynamicLibs, neededSysLibs);

        string[] libs;
        bool added;

        if (neededStaticLibs !is null) {
            fatal("Dynamic lib %s cannot require static libs, but requires %s",
                  path, neededStaticLibs);
        }
        foreach (lib; neededDynamicLibs) {
            if (lib !is this) {
                if (action.addDependency(lib)) added = true;
                libs ~= lib.uniqueName;
            }
        }
        foreach (lib; neededSysLibs) {
            libs ~= lib.name;
        }
        if (!added) {
            action.finaliseCommand(libs);
        }

        return added;
    }
}


//
// Exe - An executable file
//
final class Exe : Binary {

    // create an executable using files from this package, linking to libraries
    // that contain any included header files, and any required system libraries.
    // Note that any system libraries required by inferred local libraries are
    // automatically linked to.
    this(ref Origin origin, Pkg pkg, string kind, string name_, string[] sourceNames) {
        // interpret kind
        string dest, desc;
        switch (kind) {
            case "dist-exe": desc = "DistExe"; dest = buildPath("dist", "bin", name_);     break;
            case "priv-exe": desc = "PrivExe"; dest = buildPath("priv", pkg.trail, name_); break;
            case "test-exe": desc = "TestExe"; dest = buildPath("priv", pkg.trail, name_); break;
            default: assert(0, "invalid Exe kind " ~ kind);
        }
        version(Windows) {
            dest = dest.setExtension(".exe");
        }

        super(origin, pkg, name_ ~ "-exe", dest, sourceNames, []);

        LinkCommand *linkCommand = sourceExt in linkCommands;
        errorUnless(linkCommand && linkCommand.executable != null, origin,
                    "No command to link and executable from sources of extension %s", sourceExt);

        action = new Action(origin, pkg, format("%-15s %s", desc, dest),
                            linkCommand.executable, [this], objs);

        if (kind == "test-exe") {
            File result = new File(origin, pkg, name ~ "-result",
                                   Privacy.PRIVATE, dest ~ "-passed", false, true);
            result.action = new Action(origin,
                                       pkg,
                                       format("%-15s %s", "TestResult", result.path),
                                       format("TEST %s", this.path),
                                       [result],
                                       [this]);
        }
    }

    // Called just before our action is issued - augment the action's command string
    // with the library dependencies that we should now know about via includeAdded().
    // Return true if dependencies were added.
    override bool augmentAction() {
        StaticLib[]  neededStaticLibs;
        DynamicLib[] neededDynamicLibs;
        SysLib[]     neededSysLibs;

        neededLibs(this, [this], neededStaticLibs, neededDynamicLibs, neededSysLibs);

        string[] libs;
        bool added;

        foreach (lib; neededStaticLibs) {
            if (action.addDependency(lib)) added = true;
            libs ~= lib.uniqueName;
        }
        foreach (lib; neededDynamicLibs) {
            if (action.addDependency(lib)) added = true;
            libs ~= lib.uniqueName;
        }
        foreach (lib; neededSysLibs) {
            libs ~= lib.name;
        }
        if (!added) {
            action.finaliseCommand(libs);
        }
        return added;
    }
}


//
// Add a misc file and its target(s), either copying the specified path into
// destDir, or using a configured command to create the target file(s) if the
// specified source file has a command extension.
//
// If the specified path is a directory, add all its contents instead.
//
void miscFile(ref Origin origin, Pkg pkg, string dir, string name, string dest) {
    if (name[0] == '.') return;

    string fromPath = buildPath("src", pkg.trail, dir, name);

    if (isDir(fromPath)) {
        foreach (string path; dirEntries(fromPath, SpanMode.shallow)) {
            miscFile(origin, pkg, buildPath(dir, name), path.baseName(), dest);
        }
    }
    else {
        // Create the source file
        string ext        = extension(name);
        string relName    = buildPath(dir, name);
        File   sourceFile = File.addSource(origin, pkg, relName, Privacy.PUBLIC, false);

        // Decide on the destination directory.
        string destDir = dest.length == 0 ?
            buildPath("priv", pkg.trail, dir) :
            buildPath("dist", dest, dir);

        GenerateCommand *generate = ext in generateCommands;
        if (generate is null) {
            // Target is a simple copy of source file, preserving execute permission.
            File destFile = new File(origin, pkg, relName ~ "-copy", Privacy.PUBLIC,
                                     buildPath(destDir, name), false, true);
            destFile.action = new Action(origin,
                                         pkg,
                                         format("%-15s %s", "Copy", destFile.path),
                                         "COPY ${INPUT} ${OUTPUT}",
                                         [destFile],
                                         [sourceFile]);
        }
        else {
            // Generate the target file(s) using a configured command.
            File[] files;
            string suffixes;
            foreach (suffix; generate.suffixes) {
                string destName = stripExtension(name) ~ suffix;
                File gen = new File(origin, pkg, destName, Privacy.PRIVATE,
                                    buildPath(destDir, destName), false, true);
                files    ~= gen;
                suffixes ~= suffix ~ " ";
            }
            errorUnless(files.length > 0, origin, "Must have at least one destination suffix");
            Action action = new Action(origin,
                                       pkg,
                                       format("%-15s %s", ext ~ "->" ~ suffixes, sourceFile.path),
                                       generate.command,
                                       files,
                                       [sourceFile]);
            foreach (gen; files) {
                gen.action = action;
            }
        }
    }
}


//
// Process a Bubfile
//
void processBubfile(string indent, Pkg pkg) {
    static bool[Pkg] processed;
    if (pkg in processed) return;
    processed[pkg] = true;

    if (g_print_rules) say("%sprocessing %s", indent, pkg.bubfile);
    indent ~= "  ";
    foreach (statement; readBubfile(pkg.bubfile.path)) {
        if (g_print_rules) say("%s%s", indent, statement.toString());
        switch (statement.rule) {

            case "contain":
                foreach (name; statement.targets) {
                    errorUnless(dirName(name) == ".", statement.origin,
                                "Contained packages have to be relative");
                    Privacy privacy = privacyOf(statement.origin, statement.arg1);
                    Pkg newPkg = new Pkg(statement.origin, pkg, name, privacy);
                    processBubfile(indent, newPkg);
                }
            break;

            case "refer":
                foreach (trail; statement.targets) {
                    Pkg* other = cast(Pkg*) (trail in Node.byTrail);
                    if (other is null) {
                        // create the referenced package which must be top-level, then refer to it
                        errorUnless(dirName(trail) == ".",
                                    statement.origin,
                                    "Previously-unknown referenced package %s has to be top-level",
                                    trail);
                        Pkg newPkg = new Pkg(statement.origin,
                                             Node.byTrail["root"],
                                             trail,
                                             Privacy.PUBLIC);
                        processBubfile(indent, newPkg);
                        pkg.addReference(statement.origin, newPkg);
                    }
                    else {
                        // refer to the existing package
                        errorUnless(other !is null, statement.origin,
                                    "Cannot refer to unknown pkg %s", trail);
                        pkg.addReference(statement.origin, *other);
                    }
                }
            break;

            case "static-lib":
            case "public-lib":
            {
                errorUnless(statement.targets.length == 1, statement.origin,
                            "Can only have one static-lib name per statement");
                StaticLib lib = new StaticLib(statement.origin,
                                              pkg,
                                              statement.targets[0],
                                              statement.arg1,
                                              statement.arg2,
                                              statement.rule == "public-lib");
            }
            break;

            case "dynamic-lib":
            {
                errorUnless(statement.targets.length == 1, statement.origin,
                            "Can only have one dynamic-lib name per statement");
                new DynamicLib(statement.origin,
                               pkg,
                               statement.targets[0],
                               statement.arg1);
            }
            break;

            case "dist-exe":
            case "priv-exe":
            case "test-exe":
            {
                errorUnless(statement.targets.length == 1,
                            statement.origin,
                            "Can only have one exe name per statement");
                Exe exe = new Exe(statement.origin,
                                  pkg,
                                  statement.rule,
                                  statement.targets[0],
                                  statement.arg1);
            }
            break;

            case "misc":
            {
                foreach (name; statement.targets) {
                    miscFile(statement.origin,
                             pkg,
                             "",
                             name,
                             statement.arg1.length == 0 ? "" : statement.arg1[0]);
                }
            }
            break;

            default:
            {
                error(statement.origin, "Unsupported statement '%s'", statement.rule);
            }
        }
    }
}


//
// Remove any files in obj, priv and dist that aren't marked as needed
//
void cleandirs() {
    void cleanDir(string name) {
        //say("cleaning dir %s, cdw=%s", name, getcwd);
        if (exists(name) && isDir(name)) {
            bool[string] dirs;
            foreach (DirEntry entry; dirEntries(name, SpanMode.depth, false)) {
                //say("  considering %s", entry.name);
                bool isDir = attrIsDir(entry.linkAttributes);

                if (!isDir) {
                    File* file = entry.name in File.byPath;
                    if (file is null || (*file) !in File.allBuilt) {
                        say("Removing unwanted file %s", entry.name);
                        std.file.remove(entry.name);
                    }
                    else {
                        // leaving a file in place
                        dirs[entry.name.dirName()] = true;
                    }
                }
                else {
                    if (entry.name !in dirs) {
                        //say("removing empty dir %s", entry.name);
                        rmdir(entry.name);
                    }
                    else {
                        //say("  keeping non-empty dir %s", entry.name);
                        dirs[entry.name.dirName()] = true;
                    }
                }
            }
        }
    }
    cleanDir("obj");
    cleanDir("priv");
    cleanDir("dist");
}


//
// Planner function
//
bool doPlanning(uint                 numWorkers,
                bool                 printStatements,
                bool                 printDeps,
                bool                 printDetails,
                PlannerProtocol.Chan plannerChannel,
                WorkerProtocol.Chan  workerChannel) {

    uint inflight;

    // Ensure tmp exists so the workers have a sandbox.
    if (!exists("tmp")) {
        mkdir("tmp");
    }

    // set up some globals
    readOptions();
    g_print_rules   = printStatements;
    g_print_deps    = printDeps;
    g_print_details = printDetails;

    string projectPackage = getOption("PROJECT");
    errorUnless(projectPackage.length > 0, Origin(), "No project directory specified");

    int needed;
    try {
        // read the project Bubfile and descend into all those it refers to
        auto root = new Node();
        auto project = new Pkg(Origin(), root, projectPackage, Privacy.PRIVATE);
        processBubfile("", project);

        // clean out unwanted files from the build dir
        cleandirs();

        // Now that we know about all the files and have the mostly-complete
        // dependency graph (just includes to go), touch all source files, which is
        // enough to trigger building everything.
        foreach (path, file; File.byPath) {
            if (!file.built) {
                file.touch();
            }
        }

        while (File.outstanding.length) {

            // Issue more actions till inflight matches number of workers.
            while (inflight < numWorkers && !Action.queue.empty) {
                const Action next = Action.queue.front();
                Action.queue.popFront();

                string targets;
                foreach (target; next.builds) {
                    ensureParent(target.path);
                    if (targets.length > 0) {
                        targets ~= "|";
                    }
                    targets ~= target.path;
                }
                WorkerProtocol.sendWork(workerChannel, next.name, next.command, targets);
                ++inflight;
            }

            if (!inflight) {
                fatal("Nothing to do and no inflight actions - something is wrong");
            }

            // Wait for a worker to report back.
            auto msg = plannerChannel.receive();
            final switch (msg.type) {
                case PlannerProtocol.Type.Success:
                {
                    --inflight;
                    foreach (file; Action.byName[msg.success.action].builds) {
                        file.updated();
                    }
                    break;
                }
                case PlannerProtocol.Type.Bailed:
                {
                    fatal("Aborting build due to action failure.");
                    break;
                }
            }
        }
    }
    catch (BailException ex) {}
    catch (Exception ex) { say("Unexpected exception %s", ex); }

    if (!File.outstanding.length) {
        // Print some statistics and report success.
        say("\n"
            "Total number of files:             %s\n"
            "Number of target files:            %s\n"
            "Number of files updated:           %s\n",
            File.byPath.length, File.numBuilt, File.numUpdated);
        return true;
    }

    // Report failure.
    return false;
}



