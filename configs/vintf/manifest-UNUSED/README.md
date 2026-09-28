# manifest-UNUSED

Stock VINTF fragments deliberately NOT merged via DEVICE_MANIFEST_FILE
(which wildcards `manifest/*.xml` only -- anything here is inert).

- `android.hardware.cas@1.2-service-lazy.xml`: the 32-bit-only legacy CAS
  stack was dropped from the blob list (platform defines the module names;
  renaming 5 self-contained 32-bit files is surgery without a symptom).
  Declaring it would be declared-but-unimplemented. Widevine L1 is
  MTK-native here; DRM plugins (both ABIs) are kept. Tester gate (DRM Info
  + video playback) adjudicates; if CAS proves needed, the stack comes back
  as a unit (binaries + rc + this fragment), never piecemeal.
