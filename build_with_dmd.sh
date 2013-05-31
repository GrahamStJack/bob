#!/bin/bash
dmd -g -property -w -wi bob_config.d -O -ofbob-config
dmd -g -property -w -wi bob.d concurrency.d -O -ofbob
