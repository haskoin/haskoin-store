FROM debian:stretch

###
### Install Debian Packages
###

RUN apt-get update

RUN apt-get -y install \
    libgflags-dev \
    libsnappy-dev \
    zlib1g-dev \
    libbz2-dev \
    liblz4-dev \
    libzstd-dev \
    libtinfo-dev \
    curl \
    autoconf \
    libtool-bin \
    build-essential

###
### Install RocksDB
###

ADD https://github.com/facebook/rocksdb/archive/v5.13.1.tar.gz \
     /usr/src/rocksdb-5.13.1.tar.gz

WORKDIR /usr/src

RUN tar -zxf rocksdb-5.13.1.tar.gz

WORKDIR /usr/src/rocksdb-5.13.1

RUN make shared_lib

RUN make install-shared

###
### Install Stack
###

RUN curl -sSL https://get.haskellstack.org/ | sh

RUN stack setup 8.2.2

###
### Install Haskoin Store
###

WORKDIR /usr/src/haskoin

ADD . /usr/src/haskoin

RUN stack --extra-lib-dirs=/usr/local/lib install

RUN cp /root/.local/bin/haskoin-store /usr/local/bin

###
### Run Haskoin Store
###

EXPOSE 3000

CMD ["/usr/local/bin/haskoin-store", "--discover", "--network", "cashtest"]
