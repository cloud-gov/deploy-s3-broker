#!/bin/sh

set -e

cd s3-broker
go get -v ./...

go test -v ./...

