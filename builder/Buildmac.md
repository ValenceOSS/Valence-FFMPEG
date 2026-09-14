# valence-ffmpeg portable versions builder for mac

Portable versions builder of valence-ffmpeg for macOS.

This script is generally made for GitHub Actions' CI runner, and there will be some caveats when running it locally.

A significant limitation is that this script will mutate files in a way that prevents the script from being executed multiple times on a non-clean environment. Follow the instructions below to work with it.

## Why this target exists

VideoToolbox cannot be passed into a container on macOS. Docker Desktop runs a Linux VM, and so does Apple's own `container` framework; neither exposes the host's VideoToolbox. So anything containerised on a Mac transcodes in software, whatever the hardware underneath, and a Mac that wants its own encoder has to install natively.

Homebrew's ffmpeg is not a substitute. It has `scale_vt`, which is upstream, and none of the VideoToolbox filters this repository patches in — so a Mac running on it burns subtitles and tone maps HDR in system memory. Valence probes the build and picks its route from what it finds, so that is slower rather than broken, but it is slower than the hardware can manage.

Apple silicon only. `buildmac.sh` still knows how to cross-compile the Intel target, and CI does not ask it to: every VideoToolbox measurement so far is on Apple silicon and there is no Intel Mac to verify against.

## Package List

For a list of included dependencies check the `scripts.d` directory.
Every file corresponds to its respective package.

For macOS, there will be additionally packages located in `images/macos` as extra static libs. The `00-dep.sh` will also setup necessary environment on a GitHub Runner. You can modify or remove it if you find it unnecessary.

## How to make a build

CI is the intended place. `.github/workflows/_meta_mac.yaml` runs this on a
`macos-latest` runner for every push and pull request, and attaches the tarball
to the release when one is published.

Prefer it to a local build, and not only out of convenience: `images/macos/00-dep.sh` uninstalls Homebrew's cmake, and the known issue below has CI removing every `libx11`-linked package to keep the binary portable. Neither is a thing to do to a machine somebody works on.

### Prerequisites

* **[Homebrew](https://brew.sh)**: Make sure Homebrew is installed and set up on your system.
* **[Xcode](https://developer.apple.com/xcode/)**: Ensure that Xcode is installed and properly configured. It's essential to have the full Xcode installation as simply installing the command line toolchain won't include the Metal SDK required for ffmpeg.
  - **Verification**: To verify that you have the Metal SDK ready, run the command `xcrun -sdk macosx metal -v`. This command should display version information about the installed Metal SDK. If you encounter an error message such as `xcrun: error: unable to find utility "metal", not a developer tool or in PATH`, it indicates that the incorrect toolchain is selected. In such cases, manually select the Xcode toolchain by running the following command:
  ```
  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
  ```

### Prepare Prefix Directory

You will need to prepare a directory to install all the libraries to. The default is `/opt/ffbuild/prefix`, which is defined in `buildmac.sh` as `FFBUILD_PREFIX`. You can either create this folder manually and give permission to the user who runs the builder, or you can modify that value to point it to another folder.

### Run Builder

Once you have your environment set up, you can simply run `buildmac.sh`, and it will download libraries and start building. This may take some time, so please be patient.

Generated artifacts will be stored to `artifacts` folder.

### Prepare for next running.

To run another clean build, the easiest way is to remove the `FFBUILD_PREFIX` folder, and then remove `valence-ffmpeg` and re-clone the repo.

If you don't want to rebuild all the dependencies, you can keep the `FFBUILD_PREFIX` folder and remove/comment out the following lines:

```shell
mkdir build
for macbase in images/macos/*.sh; do
    cd "$BUILDER_ROOT"/build
    source "$BUILDER_ROOT"/"$macbase"
    ffbuild_macbase || exit $?
done

cd "$BUILDER_ROOT"
for lib in scripts.d/*.sh; do
    cd "$BUILDER_ROOT"/build
    source "$BUILDER_ROOT"/"$lib"
    ffbuild_enabled || continue
    ffbuild_dockerbuild || exit $?
done
```

At this point, the repository could have our patches applied. You want to restore it with `QUILT_PATCHES=debian/patches quilt pop -af` before the next run.

That variable is not optional here, and it is the same one `buildmac.sh` sets. quilt defaults to reading its series from `patches`, which upstream arranged with a symlink because upstream had no such directory. This repository does — `patches/` holds the third-party patches the Linux build applies — so pointing quilt at `debian/patches` explicitly is what keeps the two from colliding.

## Installing what it produces

The artefact is a tarball of two static binaries, so there is nothing to install
beyond putting them somewhere and saying where:

```sh
sudo mkdir -p /usr/local/lib/valence-ffmpeg
sudo tar -xJf valence-ffmpeg_*_portable_macarm64-gpl.tar.xz -C /usr/local/lib/valence-ffmpeg
export VALENCE_FFMPEG=/usr/local/lib/valence-ffmpeg/ffmpeg
export VALENCE_FFPROBE=/usr/local/lib/valence-ffmpeg/ffprobe
```

Those two variables are what the transcoder reads; without them it looks for
`ffmpeg` on `PATH` and finds Homebrew's.

`curl` does not set the quarantine attribute, so a tarball fetched from the release runs as is. One downloaded through a browser will be quarantined — `xattr -dr com.apple.quarantine` on the extracted binaries clears it.

## Known issue

- If you are on an Intel Mac and have `libx11` installed with Homebrew, ffmpeg will link to Homebrew's `libx11`, making your generated binary non-portable. We work around this on GitHub's Runner by removing all installed packages that use `libx11`.
