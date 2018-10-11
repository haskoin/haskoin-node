# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

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
