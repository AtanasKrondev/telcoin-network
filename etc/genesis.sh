#!/bin/bash


mkdir -p /home/nonroot/data/genesis/validators
cp -r /home/nonroot/data/validator-1/node-info.yaml /home/nonroot/data/genesis/validators/validator-1.yaml
cp -r /home/nonroot/data/validator-2/node-info.yaml /home/nonroot/data/genesis/validators/validator-2.yaml
cp -r /home/nonroot/data/validator-3/node-info.yaml /home/nonroot/data/genesis/validators/validator-3.yaml
cp -r /home/nonroot/data/validator-4/node-info.yaml /home/nonroot/data/genesis/validators/validator-4.yaml

/usr/local/bin/telcoin genesis \
    --datadir /home/nonroot/data/ \
    --chain-id 0x1e7 \
    --epoch-duration-in-secs 60 \
    --dev-funded-account 0x748Cab9A6993A24CA6208160130b3f7b79098c6d \
    --max-header-delay-ms 1000 \
    --min-header-delay-ms 1000 \
    --consensus-registry-owner 0x748Cab9A6993A24CA6208160130b3f7b79098c6d

# create directories and copy files for each validator
for i in {1..4}; do
    mkdir -p /home/nonroot/data/validator-$i/genesis/
    cp /home/nonroot/data/genesis/genesis.yaml /home/nonroot/data/genesis/committee.yaml /home/nonroot/data/validator-$i/genesis/
    cp /home/nonroot/data/parameters.yaml /home/nonroot/data/validator-$i/
done
chown -R 1101:1101 /home/nonroot/data

echo "done"
