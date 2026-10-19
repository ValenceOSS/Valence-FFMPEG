# Vendored patches

Patches `docker-build.sh` applies to third-party sources it builds. They live
here rather than being fetched during the build.

## Why they are here

The build used to download each of these from `github.com` or
`gitlab.freedesktop.org` while it ran. Two consecutive release builds died on
two different downloads — one forty minutes in, one after two hours — with
GitHub reporting all systems operational both times. The likely cause is rate
limiting: an unauthenticated runner pulls around thirty repositories and a dozen
tarballs in a burst.

Retries were added first and did not settle it. The AMF tarball failed *after*
`wget` had already tried three times, because being rate limited is not a blip
you wait out. A file already in the repository cannot fail to download.

There is a second reason, which applies only to the Mesa patches. They were
fetched by merge request number, and a merge request is not immutable — an
author can force-push to it. The build could have changed with no commit here to
point at. Vendoring pins the contents as well as removing the fetch.

## What is here

| Patch | Upstream | Fixes |
| -- | -- | -- |
| `mediasdk/8fb9f5f.patch` | [Intel-Media-SDK/MediaSDK@8fb9f5f](https://github.com/Intel-Media-SDK/MediaSDK/commit/8fb9f5f) | Build under gcc 13 |
| `media-driver/e47702f.patch` | [intel/media-driver@e47702f](https://github.com/intel/media-driver/commit/e47702f) | VC1 decode on DG2 |
| `vpl-gpu-rt/c7eb030.patch` | [intel/vpl-gpu-rt@c7eb030](https://github.com/intel/vpl-gpu-rt/commit/c7eb030) | Missing entries in PicStruct validation |
| `vpl-gpu-rt/e025c82.patch` | [intel/vpl-gpu-rt@e025c82](https://github.com/intel/vpl-gpu-rt/commit/e025c82) | ADI issue |
| `theora/3ae2669.patch` | [xiph/theora@3ae2669](https://github.com/xiph/theora/commit/3ae2669) | Relax the autoconf requirement to 2.69 |
| `mesa/41090.patch` | [mesa!41090](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/41090) | VAAPI VPP alpha blending |
| `mesa/42181.patch` | [mesa!42181](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42181) | Misc CSC issues in VAAPI VPP |
| `mesa/42408.patch` | [mesa!42408](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42408) | VPE rotation with horizontal flip enabled |
| `mesa/42763.patch` | [mesa!42763](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42763) | Chroma swizzle mode in VK Video on GFX9 |

`vpl-gpu-rt/c7eb030.patch` is applied twice, to both MediaSDK and vpl-gpu-rt.
That is deliberate and matches what the build did when it fetched.

The Mesa patches apply to the version pinned as `mesa_ver` in `docker-build.sh`.
Changing that pin means rechecking all four.

## Refreshing one

Patches are stored exactly as upstream serves them, so the transform in the call
site — `mesa/42408.patch` is piped through `sed` before `patch` — stays visible
in `docker-build.sh` rather than being baked in here.

```sh
curl -fsSL -o patches/mesa/42408.patch \
    https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42408.patch
```

Commit the result, and say in the message what changed upstream. A patch that
arrives with no explanation is indistinguishable from one that was refreshed by
accident.

## Adding one

Download it into the directory for the project it patches, then call it from
`docker-build.sh`:

```sh
apply_local_patch some-project/abc1234.patch git apply
```

Do not add a fetch. That is the thing this directory exists to remove.
