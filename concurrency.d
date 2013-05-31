module concurrency;

import std.algorithm;
import std.stdio;
import std.ascii;
import std.conv;
import std.traits;
import std.typecons;
import std.typetuple;

import core.thread;

import core.stdc.stdlib;
import core.stdc.errno;
import core.stdc.config;

import core.sync.mutex;
import core.sync.condition;

static import linux = std.c.linux.linux;


// Provides a simple inter-thread message-passing implementation.
// * Messages cannot contain references to mutable data.
// * Message queues (Channels) are explicitly created and passed to threads as
//   arguments to spawn().
// * Channels use mutexes to provide thread safety.
// * The types of messages a Channel supports are well-defined.
// * Messages are processed in order.
// * Multiple threads can receive from the same Channel.
// * Multiple threads can send to the same Channel.
// * Channels can be used in a Selector to allow a thread to receive input
//   from multiple Channels and file-descriptor devices such as sockets and pipes.
// * There is no automatic thread-termination behaviour. Typically the
//   owner of Threads will finalize Channels to cause them to terminate.
//
// NOTE - at the time of writing, the "shared" keyword was still too broken
// to use, so it is not used here.
//
// For a usage example, see the commented-out code at the bottom of this file.


//---------------------------------------------------------------------------
// A Channel for sending messages between threads.
// An internal eventfd provides a file-descriptor to select on for removal.
// Multiple threads may add and remove messages from the queue, but usually
// one thread adds and one other thread removes.
//---------------------------------------------------------------------------

public class ChannelFinalized: Exception {
    this() { super("Channel finalized"); }
}

public class ChannelFull: Exception {
    this() { super("Channel full"); }
}

extern (C) int eventfd(int initval, int flags);

class Channel(T) if (!hasAliasing!T) {
    private {
        Mutex     _mutex;
        Condition _readCondition;
        Condition _writeCondition;
        T[]       _queue;     // Circular buffer
        size_t    _count;     // Population of queue
        size_t    _back;      // Next add position
        size_t    _front;     // next remove position
        bool      _finalized;
        int       _fd;        // eventfd file descriptor
    }

    this(size_t capacity) {
        assert(capacity > 0, "Capacity must be positive");

        _mutex          = new Mutex();
        _readCondition  = new Condition(_mutex);
        _writeCondition = new Condition(_mutex);
        _queue.length   = capacity;

        _fd = eventfd(0, 0);
        assert(_fd != -1, "Failed to open eventfd");
    }

    ~this() {
        linux.close(_fd);
    }

    // Finalise the Channel, causing it to throw ChannelFinalised on remove() when empty.
    final void finalize() {
        synchronized(_mutex) {
            _finalized = true;
            if (!_count) {
                ulong one = 1;
                linux.write(_fd, &one, one.sizeof);
                _readCondition.notifyAll();
            }
        }
    }

    // Send a message to the channel, throwing if full
    private final void sendImpl(T msg) {
        if (_count == _queue.length) {
            throw new ChannelFull();
        }
        _queue[_back] = msg;
        if (!_count) {
            ulong one = 1;
            linux.write(_fd, &one, one.sizeof);
            _readCondition.notifyAll();
        }
        ++_count;
        _back = (_back + 1) % _queue.length;
    }

    // Send a message to the channel, throwing if full
    final void send(T msg) {
        synchronized(_mutex) {
            sendImpl(msg);
        }
    }

    // Blocking version of send
    final void sendBlocking(T msg) {
        synchronized(_mutex) {
            while (_count == _queue.length) {
                _writeCondition.wait();
            }
            sendImpl(msg);
        }
    }

    // Receive the next message, blocking until one is available
    // or throwing if finalized and empty
    final T receive() {
        synchronized(_mutex) {
            while (!_count) {
                if (_finalized) {
                    throw new ChannelFinalized();
                }
                else {
                    _readCondition.wait();
                }
            }
            if (_count == _queue.length) {
                _writeCondition.notifyAll();
            }
            T msg = _queue[_front];
            --_count;
            _front = (_front + 1) % _queue.length;
            if (!_count && !_finalized) {
                ulong val = void;
                linux.read(_fd, &val, val.sizeof);
            }
            return msg;
        }
    }

    // Return the eventfd for use in a Selector.
    protected final int readFd() {
        return _fd;
    }
}


//
// Spawn and start a thread on the given run function.
//
void spawn(T...)(void function(T) run, T args) {
    void exec() {
        try {
            run(args);
        }
        catch (Throwable ex) {
            writefln("Unexpected exception: %s", ex);
            abort();
        }
    }
    auto t = new Thread(&exec);
    t.start();
}


//----------------------------------------------------------------------------------
// Code-generating templates.
//----------------------------------------------------------------------------------

string firstCap(string str) {
    char[] result = str.dup;
    if (result.length > 0) {
        result[0] = cast(char) result[0].toUpper();
    }
    return result.idup;
}

string firstLow(string str) {
    char[] result = str.dup;
    if (result.length > 0) {
        result[0] = cast(char) result[0].toLower();
    }
    return result.idup;
}

string drop(string str, int qty) {
    string result = str.idup;
    if (result.length >= qty) {
        return result[0..$-qty];
    }
    else {
        return result;
    }
}

// Template to generate code for a message struct.
template Message(string name, T...) {

    enum string fieldName = firstLow(name);
    enum string typeName  = firstCap(name);

    private string fieldsCode(T...)(string prefix,
                                    string suffix,
                                    bool   withType) {
        static if (T.length == 0) {
            return "";
        }
        else static if (T.length == 1) {
            static assert(0, "Fields must be defined as type/name pairs");
        }
        else static if (T.length == 2) {
            if (withType) {
                return prefix ~ T[0].stringof ~ " " ~ T[1] ~ suffix;
            }
            else {
                return prefix ~ T[1] ~ suffix;
            }
        }
        else {
            return
                fieldsCode!(T[0..2])(prefix, suffix, withType) ~
                fieldsCode!(T[2..$])(prefix, suffix, withType);
        }
    }

    enum string semicolonFields = fieldsCode!T("    ", ";\n", true);
    enum string commaFields     = fieldsCode!T(", ",   "",    true);
    enum string fieldNames1     = fieldsCode!T("",     ", ",  false);
    enum string fieldNames      = drop(fieldNames1, 2);

    // Return the code to be used in a mixin.
    string code() {
        string result;

        result ~= "struct " ~ typeName ~ " {\n";
        result ~= semicolonFields;
        result ~= "}\n\n";

        return result;
    }
}

// Template to generate code for a Protocol.
template Protocol(Msgs...) {

    private string messagesCode(T...)() {
        static if (T.length == 0) {
            return "";
        }
        else static if (T.length == 1) {
            return T[0].code();
        }
        else {
            return messagesCode!(T[0])() ~ messagesCode!(T[1..$])();
        }
    }

    private string enumValuesCode(T...)() {
        static if (T.length == 0) {
            return "";
        }
        else static if (T.length == 1) {
            return T[0].typeName;
        }
        else {
            return enumValuesCode!(T[0])() ~ ", " ~ enumValuesCode!(T[1..$])();
        }
    }

    private string unionMembersCode(T...)() {
        static if (T.length == 0) {
            return "";
        }
        else static if (T.length == 1) {
            return "        " ~ T[0].typeName ~ " " ~ T[0].fieldName ~ ";\n";
        }
        else {
            return unionMembersCode!(T[0])() ~ unionMembersCode!(T[1..$])();
        }
    }

    private string sendsCode(T...)() {
        static if (T.length == 0) {
            return "";
        }
        else static if (T.length == 1) {
            return
                "void send" ~ T[0].typeName ~ "(Chan chan" ~
                T[0].commaFields ~ ") {\n" ~
                "    Msg msg;\n" ~
                "    msg.type = Type." ~ T[0].typeName ~ ";\n" ~
                "    msg." ~ T[0].fieldName ~ " = " ~ T[0].typeName ~ "(" ~ T[0].fieldNames ~ ");\n" ~
                "    chan.send(msg);\n" ~
                "}\n\n";
        }
        else {
            return sendsCode!(T[0])() ~ sendsCode!(T[1..$])();
        }
    }

    // Return the code to be used in a mixin.
    string code() {
        string result = "\n";

        result ~= messagesCode!(Msgs)();

        result ~= "enum Type { " ~ enumValuesCode!(Msgs)() ~ " }\n\n";

        result ~= "struct Msg {\n";
        result ~= "    Type type;\n";
        result ~= "    union {\n";
        result ~= unionMembersCode!(Msgs)();
        result ~= "    }\n";
        result ~= "}\n\n";

        result ~= "alias Channel!(Msg) Chan;\n\n";

        result ~= "Chan channel(int capacity) {\n";
        result ~= "    return new Chan(capacity);\n";
        result ~= "}\n\n";

        result ~= sendsCode!(Msgs)() ~ "\n";

        return result;
    }

    mixin(code());
}


/+
alias Protocol!(Message!("Add",  string, "name", int, "addition")) WorkerProtocol;

alias Protocol!(Message!("Result", string, "name", int, "total"),
                Message!("Terminated")) MasterProtocol;

void doMaster() {
    auto workerChannel = new WorkerProtocol.Chan(100);
    auto masterChannel = new MasterProtocol.Chan(100);

    writefln("Spawning worker");
    spawn(&doWork, workerChannel, masterChannel);

    foreach (i; 0..10) {
        WorkerProtocol.sendAdd(workerChannel, "Item", 1);
        auto msg = masterChannel.receive();
        final switch (msg.type) {
            case MasterProtocol.Type.Result:
            {
                writefln("%s total is now %s", msg.result.name, msg.result.total);
                break;
            }
            case MasterProtocol.Type.Terminated:
            {
                break;
            }
        }
    }
    workerChannel.finalize();
    writefln("Master returning");
}

void doWork(WorkerProtocol.Chan workerChannel,
            MasterProtocol.Chan masterChannel) {
    try {
        writefln("Worker running");
        int[string] totals;

        while (true) {
            auto msg = workerChannel.receive();
            final switch (msg.type) {
                case WorkerProtocol.Type.Add:
                {
                    if (msg.add.name !in totals) {
                        totals[msg.add.name] = msg.add.addition;
                    }
                    else {
                        totals[msg.add.name] += msg.add.addition;
                    }
                    MasterProtocol.sendResult(masterChannel,
                                              msg.add.name,
                                              totals[msg.add.name]);
                }
            }
        }
    }
    catch (ChannelFinalized ex) {}
    catch (Exception ex) { writefln("Got exception %s", ex); }
    writefln("Worker terminated");
    MasterProtocol.sendTerminated(masterChannel);
}

int main(string[] args) {

    writefln("WorkerProtocol.code:\n%s", WorkerProtocol.code());
    writefln("MasterProtocol.code:\n%s", MasterProtocol.code());

    doMaster();

    return 0;
}
+/
