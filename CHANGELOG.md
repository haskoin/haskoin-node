# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2024-03-14

### Changed

- Update LTS Haskell & upstream dependencies.

## [1.0.1] - 2023-08-03

### Changed

- Add compatibility with latest LTS Haskell.

## [1.0.0] - 2023-07-28

### Changed

- Make compatible with latest haskoin-core.
- Use DuplicateRecordFields and OverloadedRecordDot.
- Simplify pub/sub queues.
- Multiple refactoring passes.

## [0.18.1] - 2022-07-27

### Fixed

- Set default port for peers where it is unset.

## [0.18.0] - 2022-07-27

### Added

- Support setting up and connecting to IPv6 peers.

## [0.17.14] - 2021-08-14

### Fixed

- Reduce verbosity on incoming header decode test.
- Show appropriate error message upon receiving empty headers.

## [0.17.13] - 2021-08-14

### Added

- Display more details about invalid incoming headers.

## [0.17.12] - 2021-05-17

### Fixed

- Do not connect to more than the maximum number of peers.

## [0.17.11] - 2021-05-17

### Added

- Display message command that disconnects a peer.

## [0.17.10] - 2021-05-17

### Fixed

- Correct disconnect timeout algorithm bug.

## [0.17.9] - 2021-05-17

### Fixed

- Add randomised timeouts to avoid disconnecting all peers.

## [0.17.2] - 2021-03-09

### Fixed

- Do not start chain actor until database initialized.

## [0.17.1] - 2021-01-08

### Changed

- Depend on haskoin-core-0.17.3.

## [0.17.0] - 2020-10-21

### Added

- Support for Bitcoin Cash November 2020 hard fork.
- BlockHeaders instance for ReaderT Chain.

## [0.16.0] - 2020-07-23

### Changed

- Add support for column families.

## [0.15.0] - 2020-07-20

### Changed

- Use new Haskell bindings for RocksDB.

## [0.14.1] - 2020-06-19

### Fixed

- Correct flawed peer locking logic in Chain actor.

## [0.14.0] - 2020-06-18

### Changed

- Massively refactor everything in a non-backwards-compatible way.
- Use MIT license.
- Bump haskoin-core.
- Bump secp256k1-haskell.

### Fixed

- Fix getting stuck on a single peer.

## [0.13.0] - 2020-05-08

### Changed

- Depend on Haskoin Store 0.13.3.
- Better code organisation.

## [0.12.0] - 2020-05-06

### Changed

- Add a test suite that simulates network instead of connecting to real one.

## [0.11.3] - 2020-05-03

### Changed

- Revert including multiline decoding error text in logs.

## [0.11.2] - 2020-05-03

### Changed

- Include header decoding error text in logs.

## [0.11.1] - 2020-05-03

### Changed

- Improve logging.

## [0.11.0] - 2020-05-03

### Changed

- Set peer too old time

## [0.10.1] - 2020-05-03

### Changed

- Disconnect old peers after 48 hours instead of 30 minutes.

## [0.10.0] - 2020-05-03

### Changed

- Move modules out of Network.Haskoin namespace.
- Add better and more logging.
- Change Manager module name and related values to PeerManager.

## [0.9.21] - 2020-04-07

### Removed

- Remove unnecessary logging.

## [0.9.20] - 2020-04-07

### Changed

- Better log messages.
- Less verbose debug logging.

## [0.9.19] - 2020-04-07

### Changed
- Better log messages.

## [0.9.18] - 2020-04-07

### Added

- More aggressive peer discovery.

## [0.9.17] - 2020-04-07

### Added

- Peers are disconnected automatically after awhile.

## [0.9.16] - 2020-02-08

### Added

- Lower bound versions for some dependencies.

## [0.9.15] - 2020-01-15

### Changed

- Update to support new `NetworkAddress` data structure from `haskoin-core`.

## [0.9.14] - 2019-12-10

### Removed

- No longer support storing peers in db as performance tradeoff doesn't justify it.

## [0.9.13] - 2019-10-08

### Changed

- Really store peers in db.

## [0.9.12] - 2019-10-08

### Changed

- Demote some logging to debug level.

## [0.9.11] - 2019-10-02

### Added

- Add `-O2` optimisations to GHC.

## [0.9.10] - 2019-04-19

### Added

- Increase debugging information where application freezes.

## [0.9.9] - 2019-04-12

### Added

- Increase debugging information.

## [0.9.8] - 2019-04-12

### Changed

- Increase version of haskoin-core to 0.9.0.
- Fix some tests.

## [0.9.7] - 2019-04-12

### Added

- More debugging.

### Changed

- Be defensive against duplicate peers.
- Increase interval between housekeeping pings.
- Replace peers in database atomically.

## [0.9.6] - 2019-04-01

### Changed

- Randomize known peers instead of keeping scores.
- Simplify peer management code to avoid freezes.
- Merge logic for chain and manager.

## [0.9.5] - 2018-11-14

### Changed

- Do not record new peers in database when peer discovery is disabled.

## [0.9.4] - 2018-11-01

### Changed

- Don't spam best block events.

## [0.9.3] - 2018-10-22

### Changed

- Correct display of milliseconds in log.
- Correct bug when receiving headers from unknown peer.
- Simplify chain syncing code.

## [0.9.2] - 2018-10-18

### Changed

- Peer dies immediately when receiving a bad message.

## [0.9.1] - 2018-10-18

### Changed

- Keep track of last synced header from a peer to avoid endless loops on large reorgs.

## [0.9.0] - 2018-10-17

### Changed

- Use an STM listener instead of a publisher for the node API.

## [0.8.2] - 2018-10-17

### Added

- Expose `ChainMessage` and `ManagerMessage` types from `Haskoin.Node` module.

## [0.8.1] - 2018-10-11

### Changed

- Corrected documentation for `killPeer` function.
- Leave time out of logic code.

## [0.8.0] - 2018-10-09

### Changed

- Peers are now killed directly instead of through peer manager.

### Removed

- Chain no longer needs peer manager.

## [0.7.2] - 2018-10-09

### Added

- Compatibility with base 4.12.

### Changed

- Update base to 4.9.

## [0.7.1] - 2018-10-09

### Added

- Allow to easily obtain a peer's publisher.

## [0.7.0] - 2018-10-09

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

## [0.6.1] - 2018-09-14

### Changed

- Fix bug where peer height did not update in certain cases.

## [0.6.0] - 2018-09-14

### Added

- Documentation everywhere.

### Changed

- Make compatible with NQE 0.5.
- Use supervisor only in peer manager.
- API quality of life changes.
- Exposed module is now only `Haskoin.Node`.

### Removed

- No more direct access to internals.

## [0.5.2] - 2018-09-10

### Changed

- Improve dependency definitions.

## [0.5.1] - 2018-09-10

### Changed

- Dependency `sec256k1` changes to `secp256k1-haskell`.

## [0.5.0] - 2018-09-09

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
