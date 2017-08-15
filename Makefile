# Makefile to build bottom-up-build with dmd on linux.

DFLAGS = -g -w -wi -de -gs -O
DMD = dmd

all : bin/bub bin/bub-config

clean :
	rm obj/* bin/*

obj/backtrace.o : bub/backtrace.d
	${DMD} ${DFLAGS} -c bub/backtrace.d -ofobj/backtrace.o

obj/support.o : bub/support.d
	${DMD} ${DFLAGS} -c bub/support.d -ofobj/support.o

obj/parser.o : bub/parser.d bub/support.d
	${DMD} ${DFLAGS} -c bub/parser.d -ofobj/parser.o

obj/planner.o : bub/planner.d bub/support.d
	${DMD} ${DFLAGS} -c bub/planner.d -ofobj/planner.o

obj/worker.o : bub/worker.d bub/support.d
	${DMD} ${DFLAGS} -c bub/worker.d -ofobj/worker.o

obj/bub_main.o : bub/bub_main.d bub/planner.d bub/worker.d bub/parser.d bub/support.d
	${DMD} ${DFLAGS} -c bub/bub_main.d -ofobj/bub_main.o

bin/bub : obj/bub_main.o obj/planner.o obj/worker.o obj/parser.o obj/support.o obj/backtrace.o
	${DMD} ${DFLAGS} obj/bub_main.o obj/planner.o obj/worker.o obj/parser.o obj/support.o obj/backtrace.o -ofbin/bub


obj/bub_config.o : bub/bub_config.d
	${DMD} ${DFLAGS} -c bub/bub_config.d -ofobj/bub_config.o

bin/bub-config : obj/bub_config.o
	${DMD} ${DFLAGS} obj/bub_config.o obj/backtrace.o -ofbin/bub-config
