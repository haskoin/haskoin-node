# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## 0.7.0
### Changed
- New version of `haskoin-core`.
- New version of `rocksdb-query`.
- Add `data-default` dependency.
- Refactor peer to make it easier to test in the future.
- Connect to one peer at a time.

### Removed
- Remove irrelevant fields from peer information.
- Remove peer block head tracking.

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
