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
  url "https://github.com/sapn95/pfadi/archive/refs/tags/v0.27.0.tar.gz"
  sha256 "359479658ac32dc4409bfe37ef6819a44c5084de5c4d567cab1724bfa9e9e16d"
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

    # `pfadi`, `pfadi ~/git`, `pfadi -R report.pdf`.
    #
    # This was two lines of shell handing $1 to /usr/bin/open. It still goes
    # through LaunchServices, which was the right half: running the executable
    # holds the terminal until the window is closed, whereas asking
    # LaunchServices returns at once, reuses a window that is already open, and
    # gets the Dock and the app switcher right. The wrong half was everything
    # else, so the shell is gone and a real command parses the arguments.
    bin.install "#{buildpath}/.build/release/pfadi-cli" => "pfadi"

    # The one-command way off Finder. Installed rather than left in the repo,
    # because somebody who installed a binary should not have to clone to find
    # the tool that makes it usable.
    bin.install "#{buildpath}/.build/release/pfadi-default" => "pfadi-default"

    man1.install "man/pfadi.1", "man/pfadi-default.1"
  end

  def caveats
    <<~CAVEATS
      To use pfadi in place of Finder, one command does the lot and says what
      macOS refuses rather than pretending:

        pfadi-default apply

      The part that genuinely replaces Finder is the file viewer: with it set,
      "Reveal in Finder" in every other application opens pfadi. It also puts a
      launcher in ~/Applications so Spotlight finds it and points `open .` in a
      terminal at pfadi. Double-clicking a folder inside Finder stays Finder's,
      and `man pfadi-default` explains exactly why.

      `pfadi-default` on its own reports what the system has now and changes
      nothing; `pfadi-default undo` puts all of it back.

      From a terminal it works without any of that:

        pfadi                    # the current folder
        pfadi ~/git ~/Downloads  # two folders, as tabs of one window
        pfadi -R ./report.pdf    # point at a file rather than opening it

      Both commands have manual pages: `man pfadi`, `man pfadi-default`.
    CAVEATS
  end

  test do
    # Launching a windowed application under `brew test` would hang, so the
    # test proves the bundle is well formed and the commands answer.
    assert_path_exists prefix/"Pfadi.app/Contents/MacOS/pfadi"
    assert_predicate prefix/"Pfadi.app/Contents/MacOS/pfadi", :executable?

    # The command must answer for itself rather than leaking the usage of
    # /usr/bin/open, which is what the shell wrapper it replaced did.
    assert_match "pfadi #{version}", shell_output("#{bin}/pfadi --version")
    assert_match "address bar", shell_output("#{bin}/pfadi --help")
    # A path that is not there is an error, not a window.
    assert_match "no such file or folder",
      shell_output("#{bin}/pfadi /nope-does-not-exist 2>&1", 1)

    # The switch tool must report and change nothing when asked for neither.
    assert_match "Nothing has been changed",
      shell_output("PFADI_APP=#{prefix}/Pfadi.app #{bin}/pfadi-default")
    assert_match "pfadi-default #{version}", shell_output("#{bin}/pfadi-default --version")

    assert_path_exists man1/"pfadi.1"
    assert_path_exists man1/"pfadi-default.1"

    system "plutil", "-lint", prefix/"Pfadi.app/Contents/Info.plist"
    assert_match version.to_s,
      shell_output("/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' " \
                   "#{prefix}/Pfadi.app/Contents/Info.plist")
  end
end
