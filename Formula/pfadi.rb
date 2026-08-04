# A formula rather than a cask, and one that compiles rather than downloads.
#
# pfadi has no Developer ID signature and is not notarised, so a prebuilt
# bundle fetched from a release would be quarantined and refuse to open. A
# binary compiled on the machine it runs on has no such problem, and the build
# takes under a minute.
class Pfadi < Formula
  desc "macOS file browser with an address bar you can click into and type"
  homepage "https://github.com/sapn95/pfadi"
  url "https://github.com/sapn95/pfadi/archive/refs/tags/v0.1.1.tar.gz"
  sha256 "d66da8a02a14c646652e51dd46072f3dae1edfc533ace5bc757b52f5f370d594"
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
    # `pfadi` and `pfadi ~/git` from a shell. The bundle is what Finder,
    # Spotlight and `open -a` want; the shim is what a terminal wants.
    bin.write_exec_script prefix/"Pfadi.app/Contents/MacOS/pfadi"
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
    system "plutil", "-lint", prefix/"Pfadi.app/Contents/Info.plist"
    assert_match version.to_s,
      shell_output("/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' " \
                   "#{prefix}/Pfadi.app/Contents/Info.plist")
  end
end
