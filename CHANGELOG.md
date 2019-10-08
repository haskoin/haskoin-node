# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## 0.9.12
### Changed
- Demote some logging to debug level.

## 0.9.11
### Added
- Add `-O2` optimisations to GHC.

## 0.9.10
### Added
- Increase debugging information where application freezes.

## 0.9.9
### Added
- Increase debugging information.

## 0.9.8
### Changed
- Increase version of haskoin-core to 0.9.0.
- Fix some tests.

## 0.9.7
### Added
- More debugging.

### Changed
- Be defensive against duplicate peers.
- Increase interval between housekeeping pings.
- Replace peers in database atomically.

## 0.9.6
### Changed
- Randomize known peers instead of keeping scores.
- Simplify peer management code to avoid freezes.
- Merge logic for chain and manager.

## 0.9.5
### Changed
- Do not record new peers in database when peer discovery is disabled.

## 0.9.4
### Changed
- Don't spam best block events.

## 0.9.3
### Changed
- Correct display of milliseconds in log.
- Correct bug when receiving headers from unknown peer.
- Simplify chain syncing code.

## 0.9.2
### Changed
- Peer dies immediately when receiving a bad message.

## 0.9.1
### Changed
- Keep track of last synced header from a peer to avoid endless loops on large reorgs.

## 0.9.0
### Changed
- Use an STM listener instead of a publisher for the node API.

## 0.8.2
### Added
- Expose `ChainMessage` and `ManagerMessage` types from `Haskoin.Node` module.

## 0.8.1
### Changed
- Corrected documentation for `killPeer` function.
- Leave time out of logic code.

## 0.8.0
### Changed
- Peers are now killed directly instead of through peer manager.

### Removed
- Chain no longer needs peer manager.

## 0.7.2
### Added
- Compatibility with base 4.12.

### Changed
- Update base to 4.9.

## 0.7.1
### Added
- Allow to easily obtain a peer's publisher.

## 0.7.0
### Added
- Versioning for chain and peer database.
- Automatic purging of chain and peer database when version changes.
- Add extra timers.
- Add publishers to every peer.

### Changed
- Full reimplementation of node API.
- Simplify peer selection and management.
- Merge manager and peer events.
- Rename configuration variables for node.
- Separate logic from actors for peer manager and chain.

### Removed
- Remove irrelevant fields from peer information.
- Remove unreliable peer block head tracking.
- Remove dependency on deprecated binary conduits.
- Remove Bloom filter support from manager.
- Remove unreliable peer request tracking code.
- Remove separate manager events.

## 0.6.1
### Changed
- Fix bug where peer height did not update in certain cases.

## 0.6.0
### Added
- Documentation everywhere.

### Changed
- Make compatible with NQE 0.5.
- Use supervisor only in peer manager.
- API quality of life changes.
- Exposed module is now only `Haskoin.Node`.

### Removed
- No more direct access to internals.

## 0.5.2
### Changed
- Improve dependency definitions.

## 0.5.1
### Changed
- Dependency `sec256k1` changes to `secp256k1-haskell`.

## 0.5.0
### Added
- New `CHANGELOG.md` file.
- Use `nqe` for concurrency.
- Peer discovery.
- RocksDB peer and block header storage.
- Support for Merkle blocks.

### Changed
- Split out of former `haskoin` repository.
- Use hpack and `package.yaml`.
- Old `haskoin-node` package now renamed to `old-haskoin-node` and deprecated.

### Removed
- Removed Old Haskoin Node package completely.
- Removed Stylish Haskell configuration file.
- Remvoed `haskoin-core` and `haskoin-wallet` packages from this repository.
