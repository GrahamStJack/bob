/**
 * Copyright 2012-2017, Graham St Jack.
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

import bub.parser;
import bub.support;

import std.algorithm;
import std.ascii;
import std.file;
import std.path;
import std.range;
import std.string;
import std.process;
import std.concurrency;

static import std.array;

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
// SysLib - represents a library outside the project.
//
final class SysLib {
    static SysLib[string] byName;
    static int            nextNumber;

    string name;
    int    number;

    static SysLib get(string name) {
        if (name !in byName) {
            return new SysLib(name);
        }
        return byName[name];
    }

    private this(string name_) {
        name   = name_;
        number = nextNumber++;
        if (name in byName) fatal("Duplicate SysLib name %s", name);
        if (name !in sysLibDefinitions) fatal("System library %s is not defined in the cfg file", name);
        byName[name] = this;
    }

    override string toString() const {
        return name;
    }

    override int opCmp(Object o) const {
        // Reverse order so sort is highest to lowest
        if (this is o) return 0;
        SysLib a = cast(SysLib)o;
        if (a is null) return  -1;
        return a.number - number;
    }

    override bool opEquals(Object o) {
        return this is o;
    }

    override nothrow @trusted size_t toHash() {
        return number;
    }
}


//
// DEPS information for the whole project, persisted between builds so that
// we don't have to re-generate it to find out if a generated file is out of date.
// The in-memory copy is loaded from storage at the start of the build,
// and updated/flushed as the build progresses.
//
// This information is used in two quite different ways:
//
// * To determine a built file's dependencies, and thus whether the built file
//   is up to date or not. This uses the old information present in the file at
//   the start of the build.
//
// * Just after all the object files to be directly incorporated into a dynamic
//   library or executable are up to date, the then-current dependencies of those
//   object files are used to determine which libraries to link with. That is, it
//   establishes new dependencies on the libraries, which may cause the build of
//   the dynamic library or executable to be delayed.
//
final class DependencyCache {
    enum string dir    = "deps";
    enum string prefix = dir ~ dirSeparator;

    string[][string] dependencies;

    this() {
        executeShell("rm DEPENDENCIES-*");

        if (dir.exists && !dir.isDir) {
            dir.remove;
        }

        if (dir.exists) {
            foreach (DirEntry entry; dir.dirEntries(SpanMode.depth, false)) {
                if (entry.linkAttributes.attrIsFile) {
                    string path      = entry.name;
                    string builtPath = path[prefix.length..$];
                    dependencies[builtPath] = path.readText.split;
                }
            }
        }
    }

    void remove(string builtPath) {
        dependencies.remove(builtPath);
        auto path = prefix ~ builtPath;
        if (path.exists) {
            path.remove;
        }
    }

    void update(string builtPath, string[] deps) {
        dependencies[builtPath] = deps.dup;

        string content;
        foreach (dep; deps) {
            if (dep != builtPath) {
                content ~= dep ~ "\n";
            }
        }

        string path    = prefix ~ builtPath;
        string tmpPath = path ~ ".tmp";
        if (!path.dirName.exists) {
            path.dirName.mkdirRecurse;
        }
        tmpPath.write(content);
        tmpPath.rename(path);
    }
};


//
// Action - specifies how to build some files, and what they depend on.
//
// Commands that generate source files are special in that all actions with a
// higher number must follow them, because otherwise the generated source files
// might be absent or stale at the time DEPS information is generated.
//
final class Action {
    static Action[]             ordered;
    static Action[string]       byName;
    static int                  nextNumber;
    static Action[]             pendingGenerators; // The generate actions, in ascending order
    static long[string]         systemModTimes;    // Mod times of system files
    static PriorityQueue!Action queue;

    Origin     origin;
    string     name;        // The name of the action
    string     command;     // The action command-string
    int        number;      // Influences build order
    File[]     inputs;      // The files that constitute this action's INPUT
    File[]     builds;      // Files that constitute this action's OUTPUT
    File[]     depends;     // Files that the action depends on
    bool[File] weakDepends; // Flags a depends as being non-dirtying
    long       newest;      // The modification time of the newest system file depended on
    string[]   libs;        // The contents of this action's LIBS
    string[]   sysLibFlags; // The flags to tack on because of syslibs that are depended on
    Action     blockedBy;   // The generate action that blocks this one
    bool       completed;   // True if the action has been completed
    bool       dirty;       // True if the action needs to be executed by a worker
    string     culprit;     // The path of the first dependency that dirtied the action
    bool       issued;      // True if the action has been queued for processing

    this(Origin origin_, Pkg pkg, string name_, string command_, File[] builds_, File[] inputs_) {
        origin   = origin;
        name     = name_;
        command  = command_;
        number   = nextNumber++;
        inputs   = inputs_;
        builds   = builds_;
        ordered ~= this;
        errorUnless(name !in byName, origin, "Duplicate command name=%s", name);
        byName[name] = this;

        foreach (dep; inputs) {
            addDependency(dep);
        }

        // All the files built by this action depend on the package's Bubfile and on Buboptions
        depends ~= File.options;
        addDependency(pkg.bubfile);

        // Recognise in-project tools in the command.
        // FIXME make this also work for tool names inside variables
        foreach (token; split(command)) {
            if (token.startsWith([buildPath("dist", "bin"), "priv"])) {
                // Find the tool
                File *tool = token in File.byPath;
                errorUnless(tool !is null, origin, "Unknown in-project tool %s", token);

                // Add the dependency.
                addDependency(*tool);
            }
        }
    }

    void addCachedDependencies() {
        // We assume that all of this action's built files have the same dependencies,
        // and treat the cached dependencies with some suspicion/leniency, as they
        // can be out of date.
        auto dependPaths = builds[0].path in File.cache.dependencies;
        if (dependPaths !is null && dependPaths.length > 0) {
            foreach (dependPath; *dependPaths) {
                if (!dependPath.isAbsolute && dependPath.dirName != ".") {
                    auto depend = dependPath in File.byPath;
                    if (depend is null) {
                        // Don't know about dependPath, or it refers to a file
                        // declared later. This is normal, because the cached dependencies
                        // can become invalidated by Bubfile changes, so just treat the
                        // built files as out of date.
                        if (g_print_deps) say("Don't have up to date dependencies for %s - " ~
                                              "treating as out of date", builds[0]);
                        newest = long.max;
                        break;
                    }
                    else {
                        // Add the dependency without checking for validity, because this
                        // cached dependency might be stale.
                        // The dependency itself is safe because the depend file is already
                        // defined so there can't be a circle.
                        if (builds[0] !in depend.dependedBy) {
                            depends ~= *depend;
                            foreach (built; builds) {
                                depend.dependedBy[built] = true;
                                if (g_print_deps) say("%s depends on %s", built, *depend);
                            }
                        }
                    }
                }
                else {
                    // Assume a system file, treating headers in the build directory like a system
                    // header because dependency-restricting rules don't apply to them
                    auto lookup = dependPath in systemModTimes;
                    if (lookup !is null) {
                        newest = max(newest, *lookup);
                    }
                    else {
                        auto modTime = dependPath.modifiedTime(false);
                        systemModTimes[dependPath] = modTime;
                        newest = max(newest, modTime);
                    }
                }
            }
        }
        else if (inputs.length > 0) {
            // We have input files with unknown dependencies, so we are out of date
            if (g_print_deps) say("Dependencies of %s are unknown - treating it as out of date", builds[0]);
            newest = long.max;
        }
    }

    // add an extra depend to this action, returning true if it is a new one
    bool addDependency(File depend) {
        if (issued) fatal("Cannot add a dependency to issued action %s", this);
        bool added;
        if (builds[0] !in depend.dependedBy) {
            foreach (built; builds) {
                built.checkCanDepend(depend);
                depend.dependedBy[built] = true;
                if (g_print_deps) say("%s depends on %s", built, depend);
            }
            depends ~= depend;
            added = true;
        }
        return added;
    }

    bool addLaterDependency(File depend) {
        bool added = addDependency(depend);
        if (added && builds.length > 1) {
           fatal("Cannot add a later dependency to an action that builds more than one file: %s", name);
        }
        return added;
    }

    // Flag this action as generating files that may be used as source files
    void setGenerate() {
        pendingGenerators ~= this;
    }

    // Return true if this action is blocked by lower-numbered actions flagged via setGenerate
    bool isBlockedByGeneratedFile() {
        if (blockedBy !is null) {
            // We already know who blocks us - we remain blocked until blockedBy is cleared
            return true;
        }
        else if (pendingGenerators.length > 0 && pendingGenerators[0].number < number) {
            // We are blocked - determine by what
            foreach (candidate; pendingGenerators) {
                if (candidate.number < number) {
                    blockedBy = candidate;
                }
                else {
                    break;
                }
            }
            return true;
        }
        else {
            // Not blocked
            return false;
        }
    }

    // Flag this action as done, and if this is a generate action, attempt to issue any
    // actions blocked by it.
    //
    // Note: generate actions are issued in monotonically increasing order, as they
    // block higher-numbered actions of any kind.
    void done() {
        assert(completed);
        issued = true;
        if (pendingGenerators.length > 0 && pendingGenerators[0] is this) {
            // This is the next generate action, so any actions blocked on us are no longer
            // blocked, and all the files they generate need to be checked to see if
            // the actions can be issued
            pendingGenerators = pendingGenerators[1..$];
            File[] files;
            int fence = pendingGenerators.length == 0 ? nextNumber : pendingGenerators[0].number + 1;
            foreach (other; ordered[number+1..fence]) {
                other.blockedBy = null;
                foreach (file; other.builds) {
                    files ~= file;
                }
            }
            foreach (file; files) {
                file.issueIfReady();
            }
        }
    }

    // Set the ${LIBS} that this action will use, and any flags that are requested because of syslibs depended on
    void setLibs(string[] libs_, string[] sysLibLinkFlags) {
        libs        = libs_;
        sysLibFlags = sysLibLinkFlags;
    }

    // Set the syslib compile flags that this action will use
    void setSysLibCompileFlags(string[] sysLibCompileFlags) {
        sysLibFlags = sysLibCompileFlags;
    }

    // Return the path of any ${DEPS} file this action will use
    string depsPath() {
        return buildPath("tmp", format("DEPENDENCIES-%s", number));
    }

    // Complete this action.
    // Commands can contain any number of ${varname} instances, which are
    // replaced with the content of the named variable, cross-multiplied with
    // any adjacent text.
    // Special variables are:
    //   INPUT  -> Paths of the input files.
    //   DEPS   -> Path to a temporary dependencies file.
    //   OUTPUT -> Paths of the built files.
    //   LIBS   -> Names of all required libraries, without lib prefix or extension.
    string resolveCommandProvidingExtras(string deps = "") {
        string[string] extras;

        if (deps != "") {
            string path = deps;
            extras["DEPS"] = path;
            if (path.exists) {
                path.remove;
            }
        }

        {
            string value;
            foreach (file; inputs) {
                value ~= " " ~ file.path;
            }
            extras["INPUT"] = strip(value);
        }

        {
            string value;
            foreach (file; builds) {
                value ~= " " ~ file.path;
            }
            extras["OUTPUT"] = strip(value);
        }

        {
            string value;
            foreach (lib; libs) {
                value ~= " " ~ lib;
            }
            extras["LIBS"] = strip(value);
        }

        return resolveCommand(command, extras, sysLibFlags);
    }

    // Complete this action
    void complete() {
        assert(!completed);
        completed = true;
        command = resolveCommandProvidingExtras(depsPath);
    }

    // issue this action
    void issue(bool dirty_, string culprit_) {
        assert(completed);
        assert(!issued);
        dirty  = dirty_;
        culprit = culprit_;
        issued = true;
        queue.insert(this);
    }

    override string toString() {
        return name;
    }
    override int opCmp(Object o) const {
        // Reverse order so that a prority queue puts low numbers to the front,
        // and we also boost the priority of generate actions so that they don't
        // slow things down
        if (this is o) return 0;
        Action a = cast(Action)o;
        if (a is null) return  -1;
        int nextGenerator = pendingGenerators.length > 0 ? pendingGenerators[0].number : -1;
        if (nextGenerator == number) {
            return 1;
        }
        else if (nextGenerator == a.number) {
            return -1;
        }
        else {
            return a.number - number;
        }
    }
}


//
// Node - abstract base class for things in an ownership tree.
//
// Used to manage visibility and trails.
//

// Additional constraint on allowed dependencies
enum Privacy { PUBLIC, SEMI_PROTECTED, PROTECTED, PRIVATE }

//
// return the privacy implied by args
//
Privacy privacyOf(ref Origin origin, string[] args) {
    if (!args.length ) return Privacy.PUBLIC;
    else if (args[0] == "protected") return Privacy.PROTECTED;
    else if (args[0] == "public")    return Privacy.PUBLIC;
    else error(origin, "privacy must be one of public or protected");
    assert(0);
}


class Node {
    static Node[string] byTrail;

    string  name;    // simple name this node adds to parent
    string  trail;   // slash-separated name components from after-root to this
    Node    parent;
    Privacy privacy;
    Node[]  children;

    override string toString() const {
        return trail;
    }

    // create a node and place it into the tree
    this(Origin origin, Node parent_, string name_, Privacy privacy_) {
        errorUnless(dirName(name_) == ".",
                    origin,
                    "Cannot define node with multi-part name '%s'", name_);
        parent  = parent_;
        name    = name_;
        privacy = privacy_;

        if (parent && parent.parent) {
            // Child of non-root
            trail = buildPath(parent.trail, name);
        }
        else {
            // Root or child of the root
            trail = name;
        }

        if (parent) {
            parent.children ~= this;
        }

        errorUnless(trail !in byTrail, origin, "%s already known", trail);
        byTrail[trail] = this;
    }

    // return true if this is other or a descendant of other
    bool isDescendantOf(Node other) {
        for (auto node = this; node !is null; node = node.parent) {
            if (node is other) return true;
        }
        return false;
    }

    // return true if this is a visible descendant of other
    bool isVisibleDescendantOf(Node other) {
        // This starts out visible to itself
        Privacy effective = Privacy.PUBLIC;

        for (auto node = this; node !is null; node = node.parent) {
            if (effective == Privacy.PRIVATE) {
                // This is invisible to node
                return false;
            }
            if (node is other) {
                // Other is an ancestor and lower nodes don't render this invisible
                return true;
            }

            // Update effective privacy before advancing to parent
            if (effective > Privacy.PUBLIC) {
                // Privacy increases with distance
                ++effective;
            }
            if (node.privacy > effective) {
                // Node applies more privacy
                effective = node.privacy;
            }
        }
        // Not a descendant of other
        return false;
    }

    // Return this Node's common ancestor with another Node
    Node commonAncestorWith(Node other) {
        for (auto node = this; node !is null; node = node.parent) {
            if (node is other || other.isDescendantOf(node)) {
                return node;
            }
        }
        fatal("%s and %s have no common ancestor", this, other);
        assert(0);
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
        bubfile = File.addSource(origin, this, "Bubfile", Privacy.PUBLIC);
    }

    // Return the Pkg that directly contains or is the given Node
    static Pkg getPkgOf(Node given) {
        Node node = given;
        while (true) {
            Pkg pkg = cast(Pkg) node;
            if (pkg) {
                return pkg;
            }
            node = node.parent;
            if (!node) fatal("Node %s has no Pkg in its ancestry", given);
        }
    }
}


//
// A file
//
class File : Node {
    static DependencyCache cache;       // Cache of information gleaned from ${DEPS} in commands
    static File            options;     // The Buboptions file, which all actions depend on
    static File[]          ordered;     // Files in increasing "number" order
    static File[string]    byPath;      // Files by their path
    static bool[File]      allBuilt;    // all built files
    static bool[File]      outstanding; // outstanding buildable files
    static int             nextNumber;

    // Statistics
    static uint numBuilt;      // number of files targeted
    static uint numUpdated;    // number of files successfully updated by actions

    Origin     origin;
    string     path;           // the file's path
    int        number;         // order of file creation
    int        translateGroup; // identifies the translation group of the file, if any
    bool       built;          // true if this file will be built by an action
    Action     action;         // the action used to build this file (null if non-built)

    long       modTime;        // the modification time of this file
    bool       used;           // true if this file has been used already
    bool       augmented;      // true if augmentAction() has already been called and returned false
    bool[File] dependedBy;     // Files that depend on this

    // return a prospective path to a potential file.
    static string prospectivePath(string start, Node parent, string extra) {
        return buildPath(start, Pkg.getPkgOf(parent).trail, extra);
    }

    this(Origin origin, Node parent_, string name_, Privacy privacy_, string path_, bool built_) {
        string nodeName = name_.replace("/", "__"); // Allow files to be in subdirectories
        super(origin, parent_, nodeName, privacy_);

        this.origin = origin;

        path      = path_;
        built     = built_;

        number    = nextNumber++;

        modTime   = path.modifiedTime(built);

        errorUnless(path !in byPath, origin, "%s already defined", path);
        ordered     ~= this;
        byPath[path] = this;

        if (built) {
            ++numBuilt;
            allBuilt[this] = true;
            outstanding[this] = true;
        }
    }

    // Add a source file specifying its trail within its package
    static File addSource(Origin origin, Node parent, string extra, Privacy privacy) {

        // possible paths to the file
        string path1 = prospectivePath("obj", parent, extra);  // a built file in obj directory tree
        string path2 = prospectivePath("src", parent, extra);  // a source file in src directory tree

        string name = extra.replace("/", "__");

        File * file = path1 in byPath;
        if (file) {
            // this is a built source file we already know about
            errorUnless(!file.used, origin, "%s has already been used", path1);
            return *file;
        }
        else if (path2.exists) {
            // a source file under src
            return new File(origin, parent, name, privacy, path2, false);
        }
        else {
            error(origin, "Could not find source file %s in %s, or %s", name, path1, path2);
            assert(0);
        }
    }

    // Add a non-source input file that may be in any of src/<chain>, priv/<chain> or dist/<dir>
    static File addGenerateInput(Origin origin, Node parent, string distDir, string extra, Privacy privacy) {

        // possible paths to the file
        string path1 = prospectivePath("priv", parent, extra); // a built file in priv
        string path2 = buildPath("dist", distDir, extra);      // a built file in dist
        string path3 = prospectivePath("src", parent, extra);  // a file in src directory tree

        string name = extra.replace("/", "__");

        if (auto file = path1 in byPath) {
            // this is a built non-source file in priv that we already know about
            errorUnless(!file.used, origin, "%s has already been used", path1);
            return *file;
        }
        else if (auto file = path2 in byPath) {
            // this is a built non-source file in dist that we already know about
            errorUnless(!file.used, origin, "%s has already been used", path2);
            return *file;
        }
        else if (path3.exists) {
            // a file under src
            return new File(origin, parent, name, privacy, path3, false);
        }
        else {
            error(origin, "Could not find file %s in %s, %s or %s", name, path1, path2, path3);
            assert(0);
        }
    }

    // This file has been updated
    final void updated(string[] inputs) {
        ++numUpdated;
        modTime = path.modifiedTime(true);
        if (g_print_deps) say("Updated %s", this);

        // Remove this built file's cached dependencies so that we won't have stale ones
        // in a subsequent run if the checks below fail
        cache.remove(path);

        // Extract updated dependency information from action.depsPath,
        // validate it, and update the cache.
        // We don't actually update the action's dependencies here, because they apply to the
        // next bub run - but we have to make sure that they will be valid then.
        string[] deps = parseDeps(action.depsPath, inputs);
        bool[string] isInput;
        foreach (input; inputs) isInput[input] = true;
        foreach (dep; deps) {
            if (!dep.isAbsolute && dep.dirName != "." && dep !in isInput && dep != path) {
                // dep is an in-project source file not in "." that isn't one of the inputs or this file
                File* depend = dep in File.byPath;
                errorUnless(depend !is null, origin, "%s depends on unknown '%s'", this, dep);
                if (g_print_deps && this !in depend.dependedBy) {
                    say("After update, %s will depend on %s", this, *depend);
                }
                checkCanDepend(*depend);
            }
        }

        // Success - put new information back into cache
        cache.update(path, deps);

        upToDate();
    }

    // Mark this file as up to date
    final void upToDate() {
        auto act = action;
        action = null;
        outstanding.remove(this);

        act.done();

        // Actions that depend on this may be able to be issued now
        foreach (other; dependedBy.keys) {
            other.issueIfReady();
        }
    }

    // Advance this file's action through its states:
    // waiting-to-issue-action, action-issued, up-to-date
    final void issueIfReady() {
        if (action !is null && !action.issued) {
            bool wait;
            bool dirty = action.newest > modTime;
            string reason = "non-project dependency";
            if (dirty && g_print_deps) say("%s system dependencies are younger", this);

            if (action.isBlockedByGeneratedFile) {
                // Wait even though this file might otherwise be up to date or buildable,
                // as it might depend on a generated file that isn't yet built.
                // We do this test before looking at action.depends as it is cheap.
                wait = true;
                if (g_print_deps) say("%s [%s] waiting for generated files", path, action.number);
            }
            else {
                foreach (depend; action.depends) {
                    if (depend.action !is null) {
                        if (g_print_deps) say("%s waiting for %s", this, depend);
                        wait = true;
                        break;
                    }
                    else if (!dirty) {
                        if (depend.modTime > modTime && depend !in action.weakDepends) {
                            if (g_print_deps) say("%s dependency %s is younger", this, depend);
                            dirty = true;
                            reason  = depend.path;
                            // Don't break here, because other dependencies may force us to wait
                        }
                    }
                }
                if (!wait && g_print_deps) say("%s dependencies are up to date", this);

                if (!wait && !augmented) {
                    // All our currently known dependencies are satisfied but we aren't yet sure
                    // we know what all our dependencies are - add any more that we can now,
                    // and if they aren't already satisfied, we still have to wait.
                    wait = augmentAction();
                    if (!wait) {
                        augmented = true;

                        // re-check if we are are now dirty, then issue
                        issueIfReady;
                        return;
                    }
                }
            }
            if (!wait) {
                // Complete and issue the action, regardless of whether this file is dirty or not.
                // When the action is taken off the priority queue, it is given to a worker if dirty,
                // and otherwise upTodate() is called. We do this because calling upToDate() here
                // would cause unboundedly deep recursion.
                action.complete();
                accumulateCompletedCommand(action);
                action.issue(dirty, reason);
            }
        }
    }

    // Update this File's dependencies, returning true if dependencies have been added
    // that are not yet satisfied. Called once when the last of this File's originally
    // known dependencies are up to date.
    //
    // File specialisations that use the DependencyCache to determine things like
    // dependencies on libraries and what libraries to link with should specialise
    // this function.
    bool augmentAction() {
        return false;
    }

    // Check that this file can depend on other
    final void checkCanDepend(File other) {
        Pkg  thisPkg        = Pkg.getPkgOf(this);
        Pkg  otherPkg       = Pkg.getPkgOf(other);
        Node commonAncestor = commonAncestorWith(other);

        errorUnless(this.number > other.number ||
                    (!other.built && this.translateGroup > 0 && this.translateGroup == other.translateGroup) ||
                    other.isDescendantOf(this),
                    origin,
                    "%s cannot depend on later-defined %s",
                    this,
                    other);
        errorUnless(thisPkg is otherPkg || !thisPkg.isDescendantOf(otherPkg),
                    origin,
                    "%s (%s) cannot depend on %s (%s), whose package is an ancestor",
                    this, this.trail, other, other.trail);
        errorUnless(other.isVisibleDescendantOf(commonAncestor), origin,
                    "%s (%s) cannot depend on %s (%s), which isn't visible via %s (%s)",
                    this, this.trail, other, other.trail, commonAncestor, commonAncestor.trail);
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

    override bool opEquals(Object o) {
        return this is o;
    }

    override nothrow @trusted size_t toHash() {
      return number;
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
    if (!usingExt || usingExt == ".c") {
        result = newExt;
    }
    errorUnless(result == newExt || newExt == ".c", origin,
                "Cannot use object file compiled from '%s' when already using '%s'",
                newExt, usingExt);
    return result;
}


//
// Binary - a binary file which incorporates object files and 'owns' source files.
// Concrete implementations are StaticLib and Exe.
//
abstract class Binary : File {
    static Binary[File] byContent; // binaries by the source and obj files they 'contain'

    File[]       sources;
    File[]       objs;
    bool[File]   publics;
    bool[SysLib] reqSysLibs;
    string       sourceExt;

    // Create a binary using files from this package.
    // The sources may be already-known built files or source files in the repo,
    // but can't already be used by another Binary.
    this(ref Origin origin, Pkg pkg, string name_, string path_,
         string[] publicSources, string[] protectedSources, string[] sysLibs) {

        super(origin, pkg, name_, Privacy.PUBLIC, path_, true);

        // Local function to add a source file to this Binary
        void addSource(string name, Privacy privacy) {

            // Create a File to represent the named source file.
            string ext = extension(name);
            File sourceFile = File.addSource(origin, this, name, privacy);
            sources ~= sourceFile;

            errorUnless(sourceFile !in byContent, origin, "%s already used", sourceFile.path);
            byContent[sourceFile] = this;

            if (g_print_deps) say("%s contains %s", this.path, sourceFile.path);

            // Look for a command to do something with the source file.

            auto compile  = ext in compileRules;
            auto generate = ext in generateRules;

            if (compile !is null) {
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
                File obj = new File(origin, this, destName, Privacy.PUBLIC, destPath, true);
                objs ~= obj;

                errorUnless(obj !in byContent, origin, "%s already used", obj.path);
                byContent[obj] = this;

                string actionName = format("%-15s %s", "Compile", obj.path);

                obj.action = new Action(origin, pkg, actionName, compile.command, [obj], [sourceFile]);

                // Set additional compiler flags for syslibs this binary explicitly requires.
                bool[string] flags;
                foreach (lib, dummy; reqSysLibs) {
                    auto definition = lib.name in sysLibDefinitions;
                    foreach (flag; definition.compileFlags) {
                        if (flag !in flags && flag != "-std=c++11") {
                            flags[flag] = true;
                        }
                    }
                }
                obj.action.setSysLibCompileFlags(flags.keys);
            }
            else if (generate !is null) {
                // Generate more source files from sourceFile.

                File[] files;
                string suffixes;
                foreach (suffix; generate.suffixes) {
                    string destName = stripExtension(name) ~ suffix;
                    string destPath = buildPath("obj", parent.trail, destName);
                    File gen = new File(origin, this, destName, privacy, destPath, true);
                    files    ~= gen;
                    suffixes ~= suffix ~ " ";
                }
                Action genAction = new Action(origin,
                                              pkg,
                                              format("%-15s %s", ext ~ "->" ~ suffixes, files[0].path),
                                              generate.command,
                                              files,
                                              [sourceFile]);
                genAction.setGenerate();
                foreach (gen; files) {
                    gen.action = genAction;
                }

                // And add them as sources too.
                foreach (gen; files) {
                    addSource(gen.name, privacy);
                }
            }

            if (privacy == Privacy.PUBLIC) {
                // This file may need to be exported
                publics[sourceFile] = true;
            }
        }

        errorUnless(publicSources.length + protectedSources.length > 0,
                    origin,
                    "binary must have at least one source file");

        foreach (sysLibName; sysLibs) {
            reqSysLibs[SysLib.get(sysLibName)] = true;
        }
        foreach (source; publicSources) {
            addSource(source, Privacy.PUBLIC);
        }
        foreach (source; protectedSources) {
            addSource(source, Privacy.SEMI_PROTECTED); // available within the library *and* package
        }
    }
}


//
// Free function used by StaticLib, DynamicLib and Exe to finalise their actions
// by examining the now up-to-date dependency cache information in their
// object files, and adding any found dependencies on libaries, plus the
// names of those libraries and any associated compile-time flags, to the
// action that builds the target.
//
// objs are the object files that the target file explicitly contains. It
// is these that we look for cached dependency information on.
//
// Rules are also enforced:
//
// * The usual dependency rules.
//
// * If target is a dynamic library, StaticLibs aren't allowed as new dependencies.
//
// Returns true if this call adds dependencies that are not yet satisfied.
//
bool doAugmentAction(File target) {
    auto exe        = cast(Exe) target;
    auto staticLib  = cast(StaticLib) target;
    auto binary     = cast(Binary) target;
    auto dynamicLib = cast(DynamicLib) target;

    StaticLib[] directStaticLibs; // The static libs that target depends on

    //
    // Populate directStaticLibs with the target's direct static lib dependencies,
    // returning true if a new dependency is added that isn't yet satisfied.
    //

    if (binary !is null) {
        // Find out what StaticLibs the target binary depends on via its object file's
        // dependencies, and add those dependencies to it
        bool[Object] done;
        foreach (obj; binary.objs) {
            auto paths = obj.path in File.cache.dependencies;
            if (paths !is null) {
                foreach (path; *paths) {
                    if (!path.isAbsolute && path.dirName != ".") {
                        auto depend = path in File.byPath;
                        if (depend !is null) {
                            auto binaryDepend = *depend in Binary.byContent;
                            errorUnless(binaryDepend !is null, obj.origin,
                                        "%s depends on %s, which isn't contained by something",
                                        target, obj, *depend);

                            if (*binaryDepend !is target && *binaryDepend !in done) {
                                // binaryDepend is a StaticLib that isn't the target - weakly
                                // depend on it so that we will be able to use its reqStaticLibs
                                auto slib = cast(StaticLib*) binaryDepend;
                                errorUnless(slib !is null, binaryDepend.origin,
                                            "Expected %s to be a StaticLib", *binaryDepend);
                                done[*slib] = true;
                                if (target.action.addLaterDependency(*slib)) {
                                    if (staticLib !is null) {
                                        target.action.weakDepends[*slib] = true;
                                    }
                                    if (slib.action !is null) {
                                        // The dependency isn't yet satisfied - we have to try again later
                                        if (g_print_deps) say("%s depends on %s, which is not ready", target, *slib);
                                        return true;
                                    }
                                }
                                directStaticLibs ~= *slib;
                            }
                        }
                        else {
                            say("Ignoring dependency of %s on unknown file %s", obj, path);
                        }
                    }
                }
            }
        }

        if (staticLib !is null) {
            // Stash the now completely known static lib dependencies for later use by higher-level targets
            staticLib.reqStaticLibs = directStaticLibs;
        }
    }
    else {
        errorUnless(dynamicLib !is null, target.origin, "Expected %s to be a dynamic lib", target);
        directStaticLibs = dynamicLib.staticLibs;
    }

    if (staticLib !is null) {
        // Nothing more to do for static libs, which don't have a link step as such
        return false;
    }

    //
    // Translate direct static libs into a rolled-up list of all the libraries
    // that the target will need to link with, returning true if an unsatisfied depedency
    // on a dynamic lib is added
    //

    bool[Object] done;
    StaticLib[]  neededStaticLibs;
    DynamicLib[] neededDynamicLibs;
    SysLib[]     neededSysLibs;

    // Accumulate the consequences of a static lib, returning true if any now-known depedencies aren't ready
    bool accumulate(StaticLib slib) {
        if (slib !in done) {
            done[slib] = true;
            errorUnless(slib.action is null, target.origin,
                        "Expected %s dependency %s to be up to date",
                        target, slib);
            auto dlib = slib in DynamicLib.byContent;
            if (dlib !is null && dlib.number < target.number) {
                // Use *dlib instead of slib
                if (*dlib !in done) {
                    done[*dlib] = true;
                    if (*dlib !is target) {
                        neededDynamicLibs ~= *dlib;
                        if (target.action.addLaterDependency(*dlib)) {
                            if (dlib.action !is null) {
                                if (g_print_deps) say("%s depends on %s, which is not ready", target, *dlib);
                                return true;
                            }
                        }
                    }
                    // Recurse into dlib's contained static libs
                    foreach (lib; dlib.staticLibs) {
                        if (accumulate(lib)) {
                            return true;
                        }
                    }
                }
            }
            else {
                // slib isn't contained by a dynamic library that target is allowed to use.
                // Use slib if target doesn't contain it (only dynamic libs contain static libs).
                if (dynamicLib is null || dlib is null || *dlib !is target) {
                    errorUnless(dynamicLib is null || slib.objs.length == 0, target.origin,
                                "Dynamic library %s cannot link with static lib %s - add it to a dynamic library",
                                dynamicLib, slib);
                    neededStaticLibs ~= slib;
                }
                // Regardless, recurse into slib's required static libs
                foreach (lib; slib.reqStaticLibs) {
                    if (accumulate(lib)) {
                        return true;
                    }
                }
            }
            foreach (lib; slib.reqSysLibs.keys) {
                if (lib !in done) {
                    done[lib] = true;
                    neededSysLibs ~= lib;
                }
            }
        }
        return false;
    }

    foreach (slib; directStaticLibs) {
        if (accumulate(slib)) {
            return true;
        }
    }

    if (binary !is null) {
        // We also need our own required system libs
        foreach (lib; binary.reqSysLibs.keys) {
            done[lib] = true;
            neededSysLibs ~= lib;
        }
    }

    // We have complete knowledge of what libraries are needed -
    // add that information to the action

    neededStaticLibs.sort();
    neededDynamicLibs.sort();
    neededSysLibs.sort();

    string[] libs;
    foreach (lib; neededStaticLibs) {
        if (lib.objs.length > 0) {
            libs ~= lib.uniqueName;
        }
    }
    foreach (lib; neededDynamicLibs) {
        libs ~= lib.uniqueName;
    }

    // Put together the link flags needed by all the SysLibs this Binary needs,
    // eliminating duplicates while preserving order, which is highest to lowest.
    string[]    sysLibFlags;
    int[string] flagCounts;
    foreach (lib; neededSysLibs) {
        foreach (flag; sysLibDefinitions[lib.name].linkFlags) {
            if (flag !in flagCounts) {
                flagCounts[flag] = 0;
            }
            flagCounts[flag] = flagCounts[flag] + 1;
        }
    }
    foreach (lib; neededSysLibs) {
        foreach (flag; sysLibDefinitions[lib.name].linkFlags) {
            if (flagCounts[flag] == 1) {
                sysLibFlags ~= flag;
            }
            flagCounts[flag] = flagCounts[flag] - 1;
        }
    }

    target.action.setLibs(libs, sysLibFlags);

    if (g_print_deps) {
        say("Augmented action of %s, libs=%s syslibs=%s", target, libs, sysLibFlags);
    }

    return false;
}


//
// StaticLib - a static library.
//
final class StaticLib : Binary {
    string      uniqueName;
    bool        isPublic;
    StaticLib[] reqStaticLibs;

    this(ref Origin origin, Pkg pkg, string name_,
         string[] publicSources, string[] protectedSources, string[] sysLibs, bool isPublic_) {

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
        super(origin, pkg, name_, _path, publicSources, protectedSources, sysLibs);

        // Set up the library's action.
        if (objs.length == 0) {
            string actionName = format("%-15s %s", "empty-lib", path);
            string command    = "DUMMY " ~ path;
            action = new Action(origin, pkg, actionName, command, [this], objs);
        }
        else {
            string actionName = format("%-15s %s", "StaticLib", path);
            auto   rule       = sourceExt in slibRules;
            errorUnless(rule !is null, origin, "No static lib command for '%s'", sourceExt);
            action = new Action(origin, pkg, actionName, rule.command, [this], objs);
        }

        if (isPublic) {
            // This library's public sources are distributable, so we copy them into dist/include
            // TODO Convert from "" to <> #includes in .h files
            string copyBase = buildPath("dist", "include");
            foreach (source; publics.keys()) {
                string destPath = prospectivePath(copyBase, this, source.name);
                File copy = new File(origin, this, source.name ~ "-copy", Privacy.PRIVATE, destPath, true);

                copy.action = new Action(origin, pkg,
                                         format("%-15s %s", "Export", copy.path),
                                         "COPY ${INPUT} ${OUTPUT}",
                                         [copy], [source]);
            }
        }
    }

    override bool augmentAction() {
        return doAugmentAction(this);
    }
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

    this(ref Origin origin_, Pkg pkg, string name_, string[] staticTrails, string[] destDirs) {
        origin = origin_;

        uniqueName = std.array.replace(buildPath(pkg.trail, name_), dirSeparator, "-");
        if (name_ == pkg.name) uniqueName = std.array.replace(pkg.trail, dirSeparator, "-");
        string subdir = destDirs.length > 0 ? destDirs[0] : "lib";
        string _path = buildPath("dist", subdir, format("lib%s.so", uniqueName));
        version(Windows) {
            _path = _path.setExtension(".dll");
        }

        super(origin, pkg, name_ ~ "-dynamic", Privacy.PUBLIC, _path, true);

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
            checkCanDepend(*staticLib);
            staticLibs ~= *staticLib;
            byContent[*staticLib] = this;

            sourceExt = validateExtension(origin, staticLib.sourceExt, sourceExt);
        }
        errorUnless(staticLibs.length > 0, origin, "dynamic-lib must have at least one static-lib");

        // action
        string actionName = format("%-15s %s", "DynamicLib", path);
        auto   rule       = sourceExt in dlibRules;
        errorUnless(rule !is null, origin, "No link command for %s -> .dlib", sourceExt);
        File[] objs;
        foreach (staticLib; staticLibs) {
            foreach (obj; staticLib.objs) {
                objs ~= obj;
            }
        }
        errorUnless(objs.length > 0, origin, "A dynamic library must have at least one object file");
        action = new Action(origin, pkg, actionName, rule.command, [this], objs);

        // Also depend on all our contained static libs so that doAugmentAction can use
        // the dependencies of those static libs, which are only available after
        // they are up to date
        foreach (staticLib; staticLibs) {
            action.addDependency(staticLib);
        }
    }

    override bool augmentAction() {
        return doAugmentAction(this);
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
    this(ref Origin origin, Pkg pkg, string kind, string name_, string[] sourceNames, string[] sysLibs) {
        string destination() {
            switch (kind) {
            case "dist-exe": return buildPath("dist", "bin", name_);
            case "priv-exe": return buildPath("priv", pkg.trail, name_);
            case "test-exe": return buildPath("priv", pkg.trail, name_);
            default: assert(0, "invalid Exe kind " ~ kind);
            }
        }
        string description() {
            switch (kind) {
            case "dist-exe": return "DistExe";
            case "priv-exe": return "PrivExe";
            case "test-exe": return "TestExe";
            default: assert(0, "invalid Exe kind " ~ kind);
            }
        }

        super(origin, pkg, name_ ~ "-exe", destination(), sourceNames, [], sysLibs);

        auto rule = sourceExt in exeRules;
        errorUnless(rule !is null, origin, "No command to link exe from %s", sourceExt);

        action = new Action(origin, pkg, format("%-15s %s", description(), path), rule.command, [this], objs);

        if (kind == "test-exe") {
            File result = new File(origin, pkg, name ~ "-result", Privacy.PRIVATE, path ~ "-passed", true);
            result.action = new Action(origin,
                                       pkg,
                                       format("%-15s %s", "TestResult", result.path),
                                       format("TEST %s", this.path),
                                       [result],
                                       [this]);
        }
    }

    override bool augmentAction() {
        return doAugmentAction(this);
    }
}


//
// Add a translate file and its target(s), either copying the specified path into
// destDir, or using a configured command to create the target file(s) if the
// specified source file has a command extension.
//
// If the specified path is a directory, add all its contents instead.
//
// The initially specified files go into the destination without their preceding
// directory. That is:
// * "translate doc;"       will translate all the files in doc into priv/<chain>
// * "translate doc : doc;" will translate all the files in doc into dist/doc
// preserving any directory structure within doc.
//
// Dependency rules are relaxed slightly here to allow files added in a single call to
// translateFile to depend on each other regardless of the order in which they are added.
//
void translateFile(ref Origin origin, Pkg pkg, string name, string dest) {
    static int group;

    ++group;

    string destDir  = dest == "" ? buildPath("priv", pkg.trail) : buildPath("dist", dest);
    string destOmit = "";
    if (buildPath("src", pkg.trail, name).isDir) {
        destOmit = name ~ dirSeparator;
    }
    else if (name.dirName != ".") {
        destOmit = name.dirName ~ dirSeparator;
    }

    void translate(string relative) {
        string fromPath = buildPath("src", pkg.trail, relative);

        if (fromPath.isDir) {
            string srcOmit = buildPath("src", pkg.trail) ~ dirSeparator;
            foreach (string rel; dirEntries(fromPath, SpanMode.shallow)) {
                translate(rel[srcOmit.length..$]);
            }
        }
        else {
            // Create the source file
            string ext        = relative.extension;
            File   sourceFile = File.addSource(origin, pkg, relative, Privacy.PUBLIC);
            sourceFile.translateGroup = group;

            // Determine the destination path for a copy
            string copyPath = buildPath(destDir, relative[destOmit.length..$]);

            auto generate = ext in generateRules;
            if (generate is null) {
                // Target is a simple copy of source file, preserving execute permission
                string fileName = copyPath.replace("/", "__") ~ "-copy";
                File destFile = new File(origin, pkg, fileName, Privacy.PUBLIC, copyPath, true);
                destFile.translateGroup = group;
                destFile.action = new Action(origin,
                                            pkg,
                                            format("%-15s %s", "Copy", destFile.path),
                                            "COPY ${INPUT} ${OUTPUT}",
                                            [destFile],
                                            [sourceFile]);
                destFile.action.setGenerate;
            }
            else {
                // Generate the target file(s) using a configured command
                File[] files;
                string suffixes;
                foreach (suffix; generate.suffixes) {
                    string path = copyPath.stripExtension ~ suffix;
                    File gen = new File(origin, pkg, path.baseName, Privacy.PRIVATE, path, true);
                    gen.translateGroup = group;
                    files    ~= gen;
                    suffixes ~= suffix ~ " ";
                }
                errorUnless(files.length > 0, origin, "Must have at least one destination suffix");
                Action genAction = new Action(origin,
                                            pkg,
                                            format("%-15s %s", ext ~ "->" ~ suffixes, files[0].path),
                                            generate.command,
                                            files,
                                            [sourceFile]);
                genAction.setGenerate;
                foreach (gen; files) {
                    gen.action = genAction;
                }
            }
        }
    }

    translate(name);
}

//
// Add generate files and (if not already known) their inputs, using the
// given command to do so.
//
void generateFile(ref Origin origin,
                  Pkg        pkg,
                  string     targetName,
                  string[]   commandTokens,
                  string[]   inputNames,
                  string     dest) {
    string fromPath = buildPath("src", pkg.trail, dest, targetName);

    // Create the input files if they aren't already known
    File[] inputs;
    foreach (inputName; inputNames) {
        inputs ~= File.addGenerateInput(origin, pkg, dest, inputName, Privacy.PUBLIC);
    }

    // Decide on the destination directory.
    string destDir = dest.length == 0 ?
        buildPath("priv", pkg.trail) :
        buildPath("dist", dest);

    // Compose the command-line
    string commandLine = commandTokens.join(" ");

    // Generate the target file(s) using the given command
    File   target = new File(origin, pkg, targetName, Privacy.PRIVATE, buildPath(destDir, targetName), true);
    Action action = new Action(origin,
                               pkg,
                               format("%-15s %s", "Generate", target.path),
                               commandLine,
                               [target],
                               inputs);
    action.setGenerate;
    target.action = action;
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
                    Privacy privacy = privacyOf(statement.origin, statement.arg1);
                    Pkg newPkg = new Pkg(statement.origin, pkg, name, privacy);
                    processBubfile(indent, newPkg);
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
                                              statement.arg3,
                                              statement.rule == "public-lib");
            }
            break;

            case "dynamic-lib":
            {
                errorUnless(statement.targets.length == 1, statement.origin,
                            "Can only have one dynamic-lib name per statement");
                errorUnless(statement.arg1.length > 0, statement.origin,
                            "Must have at least one static lib specified");
                errorUnless(statement.arg2.length <= 1, statement.origin,
                            "Cannot specify multiple destination directories");
                new DynamicLib(statement.origin,
                               pkg,
                               statement.targets[0],
                               statement.arg1,
                               statement.arg2);
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
                                  statement.arg1,
                                  statement.arg2);
            }
            break;

            case "translate":
            {
                foreach (name; statement.targets) {
                    translateFile(statement.origin,
                                  pkg,
                                  name,
                                  statement.arg1.length == 0 ? "" : statement.arg1[0]);
                }
            }
            break;

            case "generate":
            {
                errorUnless(statement.targets.length == 1, statement.origin, "One target must be specified");
                generateFile(statement.origin,
                             pkg,
                             statement.targets[0],
                             statement.arg1,
                             statement.arg2,
                             statement.arg3.length == 0 ? "" : statement.arg3[0]);
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
// Remove any files in obj, priv and dist that aren't needed
//
void cleanDirs() {
    // Set up mapping from optional file suffixes that *might* be produced as a
    // companion file to the suffixes that they might be produced by
    bool[string][string] companionProducers;
    foreach (rule; compileRules) {
        foreach (companion; rule.suffixes[1..$]) {
            companionProducers[companion][".o"] = true;
        }
    }
    foreach (rule; slibRules) {
        foreach (companion; rule.suffixes[1..$]) {
            companionProducers[companion][".a"] = true;
        }
    }
    foreach (rule; dlibRules) {
        foreach (companion; rule.suffixes[1..$]) {
            companionProducers[companion][".so"] = true;
        }
    }
    foreach (rule; exeRules) {
        foreach (companion; rule.suffixes[1..$]) {
            companionProducers[companion][""] = true;
        }
    }

    // Return true if candidate is a companion file
    bool isCompanion(string candidate) {
        string ext = candidate.extension;
        if (ext.length > 1) {
            auto producers = ext in companionProducers;
            if (producers !is null) {
                foreach (producer; producers.keys) {
                    string primary = candidate.setExtension(producer);
                    if (primary in File.byPath) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    void cleanDir(string name, string prefix = "") {
        if (name.exists && name.isDir) {
            bool[string] unwantedFiles;
            string[]     unwantedDirs;
            bool[string] dirsWithChildren;

            // Determine what is unwanted
            foreach (DirEntry entry; name.dirEntries(SpanMode.depth, false)) {
                string path      = entry.name;
                string builtPath = path[prefix.length..$];
                if (!entry.linkAttributes.attrIsDir) {
                    // A file
                    File* file = builtPath in File.byPath;
                    if (file is null && !isCompanion(builtPath)) {
                        unwantedFiles[path] = true;
                    }
                    else {
                        dirsWithChildren[path.dirName] = true;
                    }
                }
                else {
                    // A directory - visited after all its children
                    if (path !in dirsWithChildren) {
                        unwantedDirs ~= path;
                    }
                    else {
                        dirsWithChildren[path.dirName] = true;
                    }
                }
            }

            // Remove the unwanted stuff
            foreach (path; unwantedFiles.keys) {
                say("Removing unwanted file %s", path);
                path.remove;
            }
            foreach (path; unwantedDirs) {
                say("Removing unwanted dir %s", path);
                path.rmdir;
            }
        }
    }

    cleanDir("obj");
    cleanDir("priv");
    cleanDir("dist");
    cleanDir(buildPath("deps", "obj"),  "deps" ~ dirSeparator);
    cleanDir(buildPath("deps", "priv"), "deps" ~ dirSeparator);
    cleanDir(buildPath("deps", "dist"), "deps" ~ dirSeparator);
}


bool[Pkg][Pkg] pkgDepends; // packages that a package depends on

// Accumulate package dependencies implied by this completed command
void accumulateCompletedCommand(Action action) {
    assert(action.completed);
    Pkg  targetPkg = Pkg.getPkgOf(action.builds[0]);
    auto depends   = targetPkg in pkgDepends;
    if (depends is null) {
        pkgDepends[targetPkg] = null;
        depends = targetPkg in pkgDepends;
    }
    foreach (depend; action.depends) {
        if (depend.path != "Buboptions") { // Buboptions breaks the dependency rules, and is uninteresting anyway
            auto dependPkg = Pkg.getPkgOf(depend);
            if (dependPkg !is targetPkg) {
                (*depends)[dependPkg] = true;
            }
        }
    }
}


//
// Flush compiler commands to file for use by other tools.
//
// These commands are independent of dependency information, and so should all
// be completable before *any* commands are issued.
//
// The format is:
// [
// { "directory": "<dir-path>",
//   "command":   "<command>",
//   "file":      "<source-path>" },
//   ...
// ]
//
void flushCompilerCommands() {
    string[File] commands;

    foreach (action; Action.byName) {
        if (action.builds.length == 1 &&
            action.builds[0].path.extension == ".o" &&
            action.depends.length > 0)
        {
            commands[action.depends[0]] = action.resolveCommandProvidingExtras;
        }
    }

    string file = "compile_commands.json";
    string tmp  = file ~ ".tmp";
    string content;
    string dir = getcwd;

    content ~= "[";
    bool first = true;
    foreach_reverse (f; commands.keys.sort) {
        string command = commands[f];
        if (!first) {
            content ~= ",";
        }
        content ~=
            "\n" ~
            "{ \"directory\": \"" ~ dir ~ "\",\n" ~
            "  \"command\":   \"" ~ command.replace(`\`, `\\`).replace(`"`, `\"`) ~ "\",\n" ~
            "  \"file\":      \"" ~ f.path ~ "\" }";
        first = false;
    }
    content ~= "\n]";

    if (!file.exists || content != file.readText) {
        tmp.write(content);
        tmp.rename(file);
    }
}

void flushPkgDepends() {
    string     file = "package-depends";
    string     tmp  = file ~ ".tmp";
    string     content;
    Pkg[][Pkg] result;
    Pkg[]      order;

    // Prepare the result, cleaning out pkgDepends as we go
    while (pkgDepends.length > 0) {
        foreach (pkg, depends; pkgDepends) {
            if (depends.length == 0) {
                // Low-level package - put into result
                foreach (pkg2, depends2; pkgDepends) {
                    if (pkg in depends2) {
                        depends2.remove(pkg);
                        result[pkg2] ~= pkg;
                    }
                }
                // And remove it from pkgDepends
                pkgDepends.remove(pkg);
                order ~= pkg;
                break;
            }
        }
    }

    // Convert to text
    foreach (pkg; order) {
        content ~= pkg.trail ~ " ->";
        auto depends = pkg in result;
        if (depends) {
            foreach (depend; *depends) {
                content ~= " " ~ depend.trail;
            }
        }
        content ~= "\n";
    }

    // Write to file
    if (!file.exists || content != file.readText) {
        tmp.write(content);
        tmp.rename(file);
    }
}

void flushIncludePathList() {
    string content;

    foreach (dir; options["PROJ_INC"].split) {
        content ~= dir ~ "\n";
    }
    string[] prefixes = ["-isystem", "-I"];
    bool[string] done;
    foreach (name, definition; sysLibDefinitions) {
        foreach (flag; definition.compileFlags) {
            foreach (prefix; prefixes) {
                if (flag.startsWith(prefix)) {
                    auto dir = flag[prefix.length..$];
                    if (dir !in done) {
                        done[dir] = true;
                        content ~= flag ~ "\n";
                    }
                }
            }
        }
    }

    string file = "include-paths";
    string tmp  = file ~ ".tmp";
    if (!file.exists || content != file.readText) {
        tmp.write(content);
        tmp.rename(file);
    }
}

void flushFileList() {
    string[] paths;
    foreach (path, file; File.byPath) {
        auto ext = path.extension;
        if (ext != ".o" &&
            !path.endsWith("-passed") &&
            cast(Binary) file is null &&
            cast(DynamicLib) file is null)
        {
            paths ~= path;
        }
    }
    string content;
    foreach (path; paths.sort) {
        content ~= path ~ "\n";
    }

    string file = "files-of-interest";
    string tmp  = file ~ ".tmp";
    if (!file.exists || content != file.readText) {
        tmp.write(content);
        tmp.rename(file);
    }
}


//
// Planner function
//
bool doPlanning(Tid[] workerTids) {

    int needed;
    try {
        // Read the project's Bubfiles
        auto project = new Pkg(Origin(), null, "", Privacy.PRIVATE);
        File.options = new File(Origin(), project, "Buboptions", Privacy.PUBLIC, "Buboptions", false);
        processBubfile("", project);

        // Update files that contain lists of known non-binary files and include directories
        // that may be of assistance for users with IDEs that don't understand compile_commands.json.
        // We do this here because such IDEs aren't concerned with correctness, and use the same
        // include paths for all files - so we don't have to wait until we complete the compile commands,
        // and can therefore provide a complete list even if the build fails.
        flushIncludePathList;
        flushFileList;
        flushCompilerCommands;

        // Clean out unwanted built and deps files and load the dependency cache -
        // now that we know all the built files
        cleanDirs();
        File.cache = new DependencyCache();
        foreach (name, action; Action.byName) {
            action.addCachedDependencies;
        }

        // Now that we know about all the files and have the mostly-complete
        // dependency graph (what libraries to link is still uncertain), issue
        // all the actions we can, which is enough to trigger building everything.
        foreach (file; File.ordered) {
            if (file.built) {
                file.issueIfReady();
                if (Action.pendingGenerators.length > 0 &&
                    file.action is Action.pendingGenerators[0])
                {
                    // This is the first generate action. All subsequent actions are
                    // blocked by this or following generate actions, so there is no point
                    // in going any further now.
                    break;
                }
            }
        }

        // A queue of idle worker indexes. A PriorityQueue is overkill, but it is easy to use...
        PriorityQueue!uint idle;
        for (uint index = 0; index < workerTids.length; ++index) idle.insert(index);

        while (File.outstanding.length) {
            // Send actions till there are no idle workers or no more queued actions.
            while (!idle.empty && !Action.queue.empty) {
                const Action next = Action.queue.front;
                Action.queue.popFront();

                if (next.dirty) {
                    // Pass the action to a worker
                    string targets;
                    foreach (target; next.builds) {
                        ensureParent(target.path);
                        if (targets.length > 0) {
                            targets ~= "|";
                        }
                        targets ~= target.path;
                    }

                    int index = idle.front;
                    idle.popFront();
                    if (g_print_culprit) {
                        say("%s (%s is newer)", next.name, next.culprit);
                    }
                    else {
                        say("%s", next.name);
                    }
                    workerTids[index].send(next.name, next.command, targets);
                }
                else {
                    // The action doesn't need to be performed - mark all its targets as up to date,
                    // which will either put more actions on the queue or clean out outstanding.
                    auto action = Action.byName[next.name];
                    foreach (target; action.builds) {
                        target.upToDate();
                    }
                }
            }

            if (File.outstanding.length > 0 && Action.queue.empty && idle.length == workerTids.length) {
                fatal("%s targets outstanding and no inflight actions - something is wrong",
                      File.outstanding.length);
            }

            if (idle.length != workerTids.length) {
                // We have workers on the job - wait for one of them to report back
                receive(
                    (uint index, string action) {
                        idle.insert(index);
                        string[] inputs;
                        foreach (file; Action.byName[action].inputs) {
                            inputs ~= file.path;
                        }
                        foreach (file; Action.byName[action].builds) {
                            file.updated(inputs);
                        }
                    },
                    (bool dummy) {
                        fatal("Aborting due to action failure.");
                    }
                );
            }
        }
    }
    catch (BailException ex) {}
    catch (Exception ex) { say("Unexpected exception %s", ex.msg); }

    if (File.outstanding.length == 0) {
        // Success

        // Flush the package dependency information now that we know everything
        flushPkgDepends();

        // Print some statistics and report success.
        say("\n" ~
            "Total number of files:   %s\n" ~
            "Number of target files:  %s\n" ~
            "Number of files updated: %s\n",
            File.byPath.length, File.numBuilt, File.numUpdated);
        return true;
    }
    else {
        say("\nBuild terminated with %s outstanding targets.\n", File.outstanding.length);
    }

    // Report failure.
    return false;
}
