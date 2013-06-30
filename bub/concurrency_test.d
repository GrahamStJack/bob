// A simple test of the concurrency module.
// TODO - improve it so that problems result in failure rather than hanging,
// and improve its coverage.

import bub.concurrency;

import std.stdio;
import std.ascii;

import core.thread;


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
