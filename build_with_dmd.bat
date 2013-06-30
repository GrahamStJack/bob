dmd -g -property -w -wi bub/bub_config.d -O -ofbin/bub-config.exe
dmd -g -property -w -wi bub/bub_main.d bub/planner.d bub/worker.d bub/parser.d bub/support.d bub/concurrency.d -O -ofbin/bub.exe

