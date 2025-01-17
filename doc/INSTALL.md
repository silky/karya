## the nix way

On linux, install either jack1 or jack2.  JACK support is mostly untested and
probably doesn't work, since I don't do music on linux.  Get in touch if you
can help with linux support.

Install nix and cachix.  I upload build results to `cachix` so if you use
that you can avoid building them.  Of course if you like building you can
skip all the `cachix` steps:

    ### Standard nix install, skip if you already have nix:
    bash <(curl -L https://nixos.org/nix/install)
    # On my laptop, nix installed with a max-jobs of 32, which is nuts on a
    # laptop with only 4 cores, and totally wedges it up.
    # Edit /etc/nix/nix.conf and possibly get max-jobs under control.

    ### Install cachix, skip if you like building:
    nix-env -iA cachix -f https://cachix.org/api/v1/install
    # Configure nix to use my cachix cache.
    # sudo is necessary because it wants to modify /etc/nix/nix.conf.
    sudo cachix use elaforge
    # Get nix-daemon to see the new config.  This may be unnecessary if
    # you did a single user nix install above:
    systemd-linux> sudo systemctl restart nix-daemon
    osx> sudo launchctl stop org.nixos.nix-daemon
    osx> sudo launchctl start org.nixos.nix-daemon

    ### Actually do the install:
    tools/nix-enter

This will download tons of stuff, and drop you in a subshell where that stuff
is available.  After this you'll need to run `tools/nix-enter` whenever you
want to build.  I use a special color on `PS1` when `SHLVL` > 1 to indicate
the subshell.

On OS X, by default you do not even have to install the commandline compiler
tools, because it will use the ones from nix.

This gets the "everything" build including "im" below.  Since my build file
is a mess, the non-im build is broken and I don't feel like fixing it at the
moment.  I'll probably just make the everything build the only build, now that
nix makes it easy.

Now do the rest of the build steps, same as "the traditional way" below:

- Install the "bravura" font:

    ```sh
    nix build -f default.nix fontDeps
    osx> cp $(find -L result* -name '*.otf') ~/Library/Fonts # or use FontBook
    linux> cp $(find -L result* -name '*.otf') ~/.fonts
    # I don't actually know how to install fonts on linux.  The above doesn't
    # work on nixos, instead add openlilylib-fonts.bravura to configuration.nix.
    ```

- Run `tools/setup-generic`.  Read it if you want, it's short.

- `tools/nix-enter` has already created a `Local/ShakeConfig.hs`.  Read it if
you want.

- Build shakefile: `bin/mkmk`

- Build optimized binaries: `bin/mk binaries`.  It will try to link to CoreMIDI
on the mac and to JACK on linux.  If for some reason you don't have either of
those or they don't work, you can run `midi=stub bin/mk` to link the stub MIDI
driver.  This could be useful if you are using `im` only, and don't want to
deal with JACK.  In that case, you can go non-MIDI and turn on
`LCmd.im_play_direct` to have karya play the audio itself.

- Go read `doc/quickstart.md`.

- Read `doc/DEVELOPMENT.md` if you want to do some of that.

Ignore the rest of this file!

## the traditional way

This is a lot more work than the nix way!

- On OS X, install commandline tools if you haven't already:
    `xcode-select --install`

- Install GHC, either the traditional way or `ghcup` should work.  I'm using
9.2 now and 8.8 recently, and I've dropped support for previous versions.
I do not recommend 9.0, it's known to be buggy!

- Install [non-haskell dependencies](#non-haskell-dependencies).

- Run `tools/setup-generic`.  Read it if you want, it's short.

- Update `Local/ShakeConfig.hs` to point to where those dependencies are
installed.

- Install [haskell dependencies](#haskell-dependencies).

- Build shakefile: `bin/mkmk`

- Build optimized binaries: `bin/mk binaries`.  It will try to link to CoreMIDI
on the mac and to JACK on linux.  If for some reason you don't have either of
those, you can run `midi=stub bin/mk` to link the stub MIDI driver, but now it
will never produce any MIDI so what was the point?

- On OS X, run `defaults write -g ApplePressAndHoldEnabled -bool false` to
re-enable key repeats globally.  Provided you want them to work sanely, and
not iphone-ly.  Or don't do that.  This is just reminder to myself.

- Go read `doc/quickstart.md`.

- Read `doc/DEVELOPMENT.md` if you want to do some of that.

## Non-Haskell dependencies

- Git, and make sure `user.email` and `user.name` are configured.

- Install either via package manager or manually:

    - fltk - I use >=1.3.4, but any >=1.3 should work.
    - libpcre

    Install -dev variants to get headers.  If your package manager puts headers
    in a non-standard place, e.g. `~/homebrew`, then `cabal install
    --only-dependencies` won't find it.  You'll need to add flags, e.g.:

        cabal v1-install --extra-include-dirs=$HOME/homebrew/include \
            --extra-lib-dirs=$HOME/homebrew/lib --only-dependencies

- lilypond for the lilypond backend.  This is optional.  If you never try to
compile a score via lilypond it will never notice you're missing this
dependency.

- The bravura font for music symbols:
<https://github.com/steinbergmedia/bravura/tree/master/releases> (the main page
is <http://www.smufl.org/fonts/>), and Noto for any other kind of symbol:
<https://www.google.com/get/noto/>.  I don't use fancy symbols very much, so
they're not essential.  You'll probably get some complaints at startup if
they're missing, it's harmless to ignore them.  You might see some boxes
instead of symbols if you use one of the few calls or scales that use non-ASCII
symbols.

    OS X: `cp *.otf ~/Library/Fonts` or use FontBook to install them.

    Linux: `cp *.otf ~/.fonts # or /usr/share/fonts`

    On linux, use `fc-list` to see installed fonts and their names.  For some
reason, the fonts on linux sometimes have backslashes in their names, and
sometimes not.  If there is a complaint at startup about the font not being
found you might have to edit a font name in `App/Config.hsc`.

## Haskell dependencies

You can do this either the cabal v1 way or the v2 way.

### cabal v2 way

Cabal v2 is supposed to replace v1 some day.  It has some problems I'm
hopefully able to work around.  Firstly, it can't build `hlibgit2` from
hackage, but can from head.  So clone that to some local directory, and update
`cabal.project` to point to that path if it's not /usr/local/src.  Then build
dependencies with:

    cabal v2-configure
    cabal v2-build --only-dep

If configure is unhappy about versions, remove `cabal.project.freeze` and
try again.  Then do `mkmk` and continue the steps documented above.  Hopefully
this is enough to make it work!

### cabal v1 way

Old cabal won't install binary dependencies automatically.  You probably
don't have a cabal this old, but in case you do:

    # These must be separate command lines!  Cabal is not smart about binaries.
    cabal install alex happy
    cabal install c2hs cpphs

To install the needed haskell dependencies, type:

    cabal v1-install --only-dependencies

This uses the global package db, and it must since new cabal has removed the
sandbox option.  In addition, v1 commands are probably on life-support and
will eventually be removed.

The actual build is with shake, I only use cabal to install hackage
dependencies.

If you want to build the documentation:

    my-package-manager install pandoc

You can also install pandoc with cabal but it has a ridiculous number of
dependencies.

### stack way

I removed this because no one ever used it.  There's not much reason to
use stack any more.

## 音, Im, Synth

These are all names for the offline synthesizer.  It requires a bunch of extra
dependencies.  If you did the nix way, then you'll already have them.

Otherwise, here are old docs for installing by hand, the non-nix way:

First you need more non-haskell dependencies.  Get the -dev versions as usual:

- faust - Faust had major stdlib changes a few years back, and if you use a
conservative distro, the bundled one may be too old.  Install by hand to be
sure.  I'm using `2.5.34`.

- libsamplerate - I use a local fork, with support for saving and restoring
state.  Get the `local` branch from
https://github.com/elaforge/libsamplerate/tree/local and clone to
`/usr/local/src/libsamplerate`, unless you want mess with config.  Build with
the usual `./autogen.sh && ./configure && make`.  Don't install, the shakefile
will link directly to it.  The reason is that it's common to have standard
libsamplerate installed in /usr/lib or /usr/local/lib, and I don't want to mess
up your system.

    If you cloned someplace other than `/usr/local/src/libsamplerate`, you'll
need to update Local/ShakeConfig.hs update the `libsamplerate` field with
the link and compile flags.

- libsndfile - Use your package manager.

## Misc

`tools/run_profile` expects `ps2pdf` in the path, which is part of ghostscript.
It's fine if it's not, but you'll get ps instead of pdf.  Help with heap
profiling would be very welcome!
