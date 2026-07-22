#!/bin/bash

apt-get update
apt-get install -y software-properties-common
add-apt-repository ppa:deadsnakes/ppa

apt-get update
apt-get install -y git python3.11 build-essential cmake autoconf autogen automake libtool pkg-config ragel wget xxd
apt-get remove -y cmake
apt-get install -y python3-pip
pip install --break-system-packages "cmake>=3.5,<4.0"

git config --global pull.rebase false
ln -sf /usr/bin/python3.11 /usr/bin/python