#!/bin/sh

set -e

export GOPATH=$(pwd)/gopath
export PATH=$PATH:$GOPATH/bin

cd gopath/src/github.com/cloudfoundry-community/s3-broker

go get github.com/onsi/ginkgo/ginkgo
go get github.com/onsi/gomega

ginkgo -r
