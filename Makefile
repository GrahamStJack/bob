# Makefile to build bottom-up-build with dmd on linux.

DFLAGS = -g -property -w -wi -O

all : bub bub-config


concurrency.o : concurrency.d
	dmd ${DFLAGS} -c concurrency.d -ofconcurrency.o

support.o : support.d concurrency.d
	dmd ${DFLAGS} -c support.d -ofsupport.o

parser.o : parser.d support.d
	dmd ${DFLAGS} -c parser.d -ofparser.o

planner.o : planner.d support.d concurrency.d
	dmd ${DFLAGS} -c planner.d -ofplanner.o

worker.o : worker.d support.d concurrency.d
	dmd ${DFLAGS} -c worker.d -ofworker.o

bub.o : bub.d planner.d worker.d parser.d support.d concurrency.d
	dmd ${DFLAGS} -c bub.d -ofbub.o

bub : bub.o planner.o worker.o parser.o support.o concurrency.o
	dmd ${DFLAGS} bub.o planner.o worker.o parser.o support.o concurrency.o -ofbub


bub_config.o : bub_config.d
	dmd ${DFLAGS} -c bub_config.d -ofbub_config.o

bub-config : bub_config.o
	dmd ${DFLAGS} bub_config.o -ofbub-config
