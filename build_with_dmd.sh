#!/bin/bash
dmd -g -property -w -wi process.d bob_config.d -O -ofbob-config
dmd -g -property -w -wi process.d bob.d -O -ofbob
