# Makefile to build bottom-up-build with dmd on linux.

DFLAGS = -g -w -wi -de -O

all : bin/bub bin/bub-config

clean :
	rm obj/* bin/*

obj/support.o : bub/support.d
	dmd ${DFLAGS} -c bub/support.d -ofobj/support.o

obj/parser.o : bub/parser.d bub/support.d
	dmd ${DFLAGS} -c bub/parser.d -ofobj/parser.o

obj/planner.o : bub/planner.d bub/support.d
	dmd ${DFLAGS} -c bub/planner.d -ofobj/planner.o

obj/worker.o : bub/worker.d bub/support.d
	dmd ${DFLAGS} -c bub/worker.d -ofobj/worker.o

obj/bub_main.o : bub/bub_main.d bub/planner.d bub/worker.d bub/parser.d bub/support.d
	dmd ${DFLAGS} -c bub/bub_main.d -ofobj/bub_main.o

bin/bub : obj/bub_main.o obj/planner.o obj/worker.o obj/parser.o obj/support.o
	dmd ${DFLAGS} obj/bub_main.o obj/planner.o obj/worker.o obj/parser.o obj/support.o -ofbin/bub


obj/bub_config.o : bub/bub_config.d
	dmd ${DFLAGS} -c bub/bub_config.d -ofobj/bub_config.o

bin/bub-config : obj/bub_config.o
	dmd ${DFLAGS} obj/bub_config.o -ofbin/bub-config
