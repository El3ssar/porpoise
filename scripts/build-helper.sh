#!/bin/bash
# Builds the privileged helper into Resources/Helper/PorpoiseHelper, which is committed and shipped unchanged.
#
# macOS approves the helper of an app without an Apple team ID as that exact binary (its code hash): a rebuilt
# helper, even from the same source, must be approved again by every user. So releases don't rebuild it: run this
# only when Sources/PorpoiseHelper or the parts of PorpoiseCore it uses change, then commit the new binary (and
# mention in the changelog that macOS will ask to allow Porpoise's administrator actions again).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --product PorpoiseHelper
mkdir -p Resources/Helper
cp "$(swift build -c release --arch arm64 --show-bin-path)/PorpoiseHelper" Resources/Helper/PorpoiseHelper
echo "built Resources/Helper/PorpoiseHelper; commit it"
