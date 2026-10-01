# Release verification — 2026-09-30

- Final signed Apple Silicon build, macOS 14 minimum.
- Six automated tests passed with zero failures.
- OpenRouter key survived relaunches and signed app updates in Keychain.
- Restore → Block again completed and was independently checked against Messages’ exact sender and inverse native control.
- At 22:46 EDT, a fresh bank-impersonation phishing iMessage was sent through the Super backend’s Linq route while the sender was unblocked and had no always-allowed override.
- Protection detected message `449ED870-9FCF-4EB8-A86E-6BB44E1AFD87`; Jev returned block, confidence 0.99 and block probability 0.99.
- The app automatically applied and confirmed the block. Messages independently showed the exact sender, Blocked indicator and Unblock Contact. No manual Block again action was used for this fresh test.
- The screenshot in this repository captures that result. The test sender was subsequently restored to preserve ordinary backend messages.
- Apple accepted the DMG notarization; the ticket was stapled, stapler validation passed, and Gatekeeper reported Notarized Developer ID.
- The tested and packaged executables have identical SHA-256 hashes after removing only their timestamped signatures: `03f1b67915e317a401a0f083f5bb9eced72320ca7920a74233f89d9c308a371d`.

The provider selected iMessage. This proves the tested native block and its automatic workflow, not carrier-SMS suppression, cross-device synchronization or broad classifier accuracy.
