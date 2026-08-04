# A formula rather than a cask, and one that compiles rather than downloads.
#
# pfadi has no Developer ID signature and is not notarised, so a prebuilt
# bundle fetched from a release would be quarantined and refuse to open. A
# binary compiled on the machine it runs on has no such problem, and the build
# takes under a minute.
class Pfadi < Formula
  desc "macOS file browser with an address bar you can click into and type"
  homepage "https://github.com/sapn95/pfadi"
  # url and sha256 point at the last release, not at VERSION. They trail it by
  # design: the checksum of a tag's tarball cannot be known before the tag
  # exists, so the release workflow rewrites both once it does.
  url "https://github.com/sapn95/pfadi/archive/refs/tags/v0.12.0.tar.gz"
  sha256 "67ca619ceaa8ed30c93684e32a0421ff9661108012c3289fae3550e3776a813c"
  license "MIT"
  head "https://github.com/sapn95/pfadi.git", branch: "main"

  depends_on macos: :sonoma

  def install
    odie "swift is missing: install the Xcode Command Line Tools" unless which("swift")

    # --disable-sandbox everywhere, not just here. Homebrew runs the whole
    # formula inside sandbox-exec, and SwiftPM opening a second sandbox inside
    # that one is refused by macOS with "sandbox_apply: Operation not
    # permitted". make-app.sh builds again to find the binary, so it needs the
    # same flag or the install dies after this line has already succeeded.
    ENV["PFADI_SWIFT_FLAGS"] = "--disable-sandbox"
    system "swift", "build", "-c", "release", "--disable-sandbox"
    system "./scripts/make-app.sh", "release"

    prefix.install "build/Pfadi.app"

    # `pfadi` and `pfadi ~/git` from a shell.
    #
    # Deliberately `open` rather than the binary itself. Running the executable
    # holds the terminal until the window is closed, which is the wrong shape
    # for a browser you glance at. Going through LaunchServices returns at once,
    # reuses a window that is already open, and gets the Dock and the app
    # switcher right.
    (bin/"pfadi").write <<~LAUNCHER
      #!/bin/sh
      exec /usr/bin/open -a "#{opt_prefix}/Pfadi.app" "${1:-$PWD}"
    LAUNCHER
    (bin/"pfadi").chmod 0755
  end

  def caveats
    <<~CAVEATS
      pfadi is installed as a bundle inside the Cellar. To have it show up in
      Spotlight, Launchpad and `open -a`, link it into your applications:

        ln -sfn #{opt_prefix}/Pfadi.app ~/Applications/Pfadi.app

      From a terminal it works without that:

        pfadi           # the current directory
        pfadi ~/git     # somewhere else
    CAVEATS
  end

  test do
    # Launching a windowed application under `brew test` would hang, so the
    # test proves the bundle is well formed and the binary is executable.
    assert_path_exists prefix/"Pfadi.app/Contents/MacOS/pfadi"
    assert_predicate prefix/"Pfadi.app/Contents/MacOS/pfadi", :executable?
    # The launcher must hand over to LaunchServices rather than exec the
    # binary, or `pfadi ~/git` holds the terminal it was typed into.
    assert_match "/usr/bin/open", (bin/"pfadi").read
    system "plutil", "-lint", prefix/"Pfadi.app/Contents/Info.plist"
    assert_match version.to_s,
      shell_output("/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' " \
                   "#{prefix}/Pfadi.app/Contents/Info.plist")
  end
end
