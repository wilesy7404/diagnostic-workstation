# BMW SYSTEM anchored popup positioning (v1.0.2)
# Source-of-truth integration snippet for the compact SystemPanel.ps1:
# 1. Keep exactly one xmlns:x on the Popup root.
# 2. Set Placement="Top" VerticalOffset="-7".
# 3. After assigning PlacementTarget, align popup right edge to the anchor right edge.
#
# $p.PlacementTarget = $Anchor
# $p.HorizontalOffset = $Anchor.ActualWidth - 370
#
# Avoid hard-coded HorizontalOffset="-290" because SYSTEM width and screen scaling vary.
# This is not an update to Windows or OEM diagnostic applications.
