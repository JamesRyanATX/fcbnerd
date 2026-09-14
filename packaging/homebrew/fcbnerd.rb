# Homebrew formula for fcbnerd. Copy into a tap repository
# (github.com/JamesRyanATX/homebrew-tap, as Formula/fcbnerd.rb) so users can run
# `brew install JamesRyanATX/tap/fcbnerd`.
#
# On each release: tag vX.Y.Z (matching `version` in Sources/fcbnerd/main.swift),
# then update `url` and `sha256`:
#   curl -sL <url> | shasum -a 256
class Fcbnerd < Formula
  desc "Bind MIDI foot controller events to shell commands, or stream them as JSON"
  homepage "https://github.com/JamesRyanATX/fcbnerd"
  url "https://github.com/JamesRyanATX/fcbnerd/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "REPLACE_WITH_TARBALL_SHA256"
  license "MIT"

  depends_on macos: :ventura

  def install
    # Homebrew already sandboxes the build; SwiftPM's own sandbox can't nest inside it.
    system "swift", "build", "--disable-sandbox", "--configuration", "release"
    bin.install ".build/release/fcbnerd"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/fcbnerd --version")
    assert_match "unexpected argument", shell_output("#{bin}/fcbnerd bogus 2>&1", 64)
  end
end
