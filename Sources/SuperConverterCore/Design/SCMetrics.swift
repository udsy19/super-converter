import AppKit

// Measured sizes (ux §3.5). Points throughout.

public enum SCMetrics {
    public enum Window {
        public static let defaultSize = NSSize(width: 1080, height: 700)
        public static let minimumSize = NSSize(width: 640, height: 480)
        public static let toolbarHeight: CGFloat = 52
        public static let segmentedHeight: CGFloat = 24
    }

    public enum DropZone {
        public static let inset: CGFloat = 18
        public static let cornerRadius: CGFloat = 22
        public static let dashedBorder: CGFloat = 2
        public static let dash: [CGFloat] = [6, 5]
        public static let hoverBorder: CGFloat = 3
    }

    public enum Grid {
        public static let paddingX: CGFloat = 20
        public static let paddingY: CGFloat = 22
        public static let gap: CGFloat = 18
        public static let columnWidth: CGFloat = 208
        /// The list view takes over below this window width or above this many files [D].
        public static let listBelowWidth: CGFloat = 640
        public static let listAboveCount = 60
    }

    public enum Card {
        public static let size = NSSize(width: 208, height: 250)
        public static let radius: CGFloat = 16
        public static let inset: CGFloat = 8
        public static let selectionRing: CGFloat = 2.5
        public static let thumbnailWell = NSSize(width: 192, height: 132)
        public static let thumbnailRadius: CGFloat = 11
        public static let thumbnailFit = NSSize(width: 160, height: 108)
        public static let removeButton: CGFloat = 20
        public static let nameInset: CGFloat = 6
        public static let rowBottomInset: CGFloat = 4
        public static let sourcePillHeight: CGFloat = 22
        public static let sourcePillRadius: CGFloat = 11
        public static let targetPillHeight: CGFloat = 26
        public static let targetPillRadius: CGFloat = 13
        public static let optionsButton: CGFloat = 26
        public static let flowSize = NSSize(width: 15, height: 2)
        public static let flowGap: CGFloat = 3
        public static let badgeHeight: CGFloat = 22
        public static let noticeRadius: CGFloat = 9
        public static let noticeButtonHeight: CGFloat = 22
        public static let progressCapsule: CGFloat = 6
    }

    public enum ActionBar {
        public static let height: CGFloat = 76
        public static let sidePadding: CGFloat = 20
        public static let buttonHeight: CGFloat = 44
        public static let blurRadius: CGFloat = 24
    }

    public enum Picker {
        public static let width: CGFloat = 452
        public static let radius: CGFloat = 14
        public static let searchHeight: CGFloat = 32
        public static let chipSize = NSSize(width: 78, height: 58)
        public static let chipRadius: CGFloat = 12
        public static let formatChipHeight: CGFloat = 28
        public static let formatChipMinWidth: CGFloat = 52
        public static let formatChipRadius: CGFloat = 8
        public static let formatChipGap: CGFloat = 6
        public static let categoryDot: CGFloat = 8
    }

    public enum OptionsSheet {
        public static let width: CGFloat = 600
        public static let labelColumn: CGFloat = 132
        public static let rowPadding: CGFloat = 9
    }

    public enum MenuBarPanel {
        public static let width: CGFloat = 360
        public static let radius: CGFloat = 14
        public static let rowHeight: CGFloat = 56
        public static let thumbnail: CGFloat = 40
    }

    public enum Settings {
        public static let size = NSSize(width: 820, height: 770)
        public static let helperIcon: CGFloat = 40
    }

    public enum Toolbar {
        public static let titleSize: CGFloat = 13
        public static let subtitleSize: CGFloat = 11
    }
}
