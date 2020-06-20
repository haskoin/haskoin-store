FROM debian:latest
RUN apt update
RUN apt install -y libsecp256k1-dev
RUN apt install -y librocksdb-dev
RUN apt install -y pkg-config
RUN apt install -y curl
RUN curl -sSL https://get.haskellstack.org/ | sh
RUN useradd -rm haskoin
USER haskoin:haskoin
COPY . /home/haskoin/haskoin-store
WORKDIR /home/haskoin/haskoin-store
RUN stack clean --no-terminal --full
RUN stack build --no-terminal --test --copy-bins
EXPOSE 3000/tcp
ENTRYPOINT /home/haskoin/haskoin-store/.local/bin/haskoin-store