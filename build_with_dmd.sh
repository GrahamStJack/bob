#!/bin/bash
dmd -g -property -w -wi bub_config.d -O -ofbub-config
dmd -g -property -w -wi bub.d concurrency.d -O -ofbub
