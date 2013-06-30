# Makefile to build bottom-up-build with dmd on linux.

DFLAGS = -g -property -w -wi -O

all : bin/bub bin/bub-config bin/concurrency-test


obj/concurrency.o : bub/concurrency.d
	dmd ${DFLAGS} -c bub/concurrency.d -ofobj/concurrency.o

obj/concurrency_test.o : bub/concurrency_test.d bub/concurrency.d
	dmd ${DFLAGS} -c bub/concurrency_test.d -ofobj/concurrency_test.o

bin/concurrency-test : obj/concurrency_test.o obj/concurrency.o
	dmd ${DFLAGS} obj/concurrency_test.o obj/concurrency.o -ofbin/concurrency-test


obj/support.o : bub/support.d bub/concurrency.d
	dmd ${DFLAGS} -c bub/support.d -ofobj/support.o

obj/parser.o : bub/parser.d bub/support.d
	dmd ${DFLAGS} -c bub/parser.d -ofobj/parser.o

obj/planner.o : bub/planner.d bub/support.d bub/concurrency.d
	dmd ${DFLAGS} -c bub/planner.d -ofobj/planner.o

obj/worker.o : bub/worker.d bub/support.d bub/concurrency.d
	dmd ${DFLAGS} -c bub/worker.d -ofobj/worker.o

obj/bub_main.o : bub/bub_main.d bub/planner.d bub/worker.d bub/parser.d bub/support.d bub/concurrency.d
	dmd ${DFLAGS} -c bub/bub_main.d -ofobj/bub_main.o

bin/bub : obj/bub_main.o obj/planner.o obj/worker.o obj/parser.o obj/support.o obj/concurrency.o
	dmd ${DFLAGS} obj/bub_main.o obj/planner.o obj/worker.o obj/parser.o obj/support.o obj/concurrency.o -ofbin/bub


obj/bub_config.o : bub/bub_config.d
	dmd ${DFLAGS} -c bub/bub_config.d -ofobj/bub_config.o

bin/bub-config : obj/bub_config.o
	dmd ${DFLAGS} obj/bub_config.o -ofbin/bub-config
