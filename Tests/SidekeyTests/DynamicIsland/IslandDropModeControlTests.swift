import XCTest
@testable import Sidekey

final class IslandDropModeControlTests: XCTestCase {

    func test_smartModeUsesSparklesPresentation() {
        XCTAssertEqual(IslandDropModeControl.title, "Drop Mode")
        XCTAssertEqual(IslandDropModeControl.label(for: .smart), "Smart")
        XCTAssertEqual(IslandDropModeControl.systemImage(for: .smart), "sparkles")
    }

    func test_fastModeUsesBoltPresentation() {
        XCTAssertEqual(IslandDropModeControl.label(for: .fast), "Fast")
        XCTAssertEqual(IslandDropModeControl.systemImage(for: .fast), "bolt")
    }

    func test_dropModeHoverTileDoesNotShowBottomValueLabel() {
        XCTAssertNil(IslandDropModeControl.hoverTileLabel(for: .fast))
        XCTAssertNil(IslandDropModeControl.hoverTileLabel(for: .smart))
    }

    func test_nextModeTogglesBetweenSmartAndFast() {
        XCTAssertEqual(IslandDropModeControl.nextMode(after: .smart), .fast)
        XCTAssertEqual(IslandDropModeControl.nextMode(after: .fast), .smart)
    }

    func test_dropModeStatusDisplaysForThreeSeconds() {
        XCTAssertEqual(IslandDropModeControl.statusDisplaySeconds, 3, accuracy: 0.001)
    }

    func test_dropModeStatusLabelShowsCurrentModeIsOn() {
        XCTAssertEqual(IslandDropModeControl.statusActiveLabel, "ON")
        XCTAssertEqual(IslandDropModeControl.statusModeLabel(for: .fast), "Fast")
        XCTAssertEqual(IslandDropModeControl.statusModeLabel(for: .smart), "Smart")
        XCTAssertEqual(IslandDropModeControl.statusAccessibilityLabel(for: .fast), "ON Fast")
        XCTAssertEqual(IslandDropModeControl.statusAccessibilityLabel(for: .smart), "ON Smart")
    }

    func test_dropModeStatusActiveIndicatorUsesGreenAccent() {
        XCTAssertGreaterThan(IslandDropModeStatusStyle.activeGreen, IslandDropModeStatusStyle.activeRed)
        XCTAssertGreaterThan(IslandDropModeStatusStyle.activeGreen, IslandDropModeStatusStyle.activeBlue)
        XCTAssertGreaterThan(IslandDropModeStatusStyle.activeOpacity, 0.8)
    }

    func test_dropModeStatusAvoidsInnerChipChrome() {
        XCTAssertFalse(IslandDropModeStatusStyle.usesContainerChrome)
    }

    func test_dropModeStatusActiveIndicatorUsesSimpleRing() {
        XCTAssertTrue(IslandDropModeStatusStyle.activeUsesSimpleRing)
        XCTAssertGreaterThan(IslandDropModeStatusStyle.activeRingSize, 14)
        XCTAssertLessThanOrEqual(IslandDropModeStatusStyle.activeRingSize, 22)
        XCTAssertGreaterThan(IslandDropModeStatusStyle.activeRingLineWidth, 0.5)
        XCTAssertLessThan(IslandDropModeStatusStyle.activeRingLineWidth, 2)
    }

    func test_hoverPanelLivesBelowCompactIsland() {
        // After the 2-row × 4-column refactor the panel doubled in
        // height; bounds are loosened accordingly but the lower bound
        // (must clear the compact pill height) still holds.
        XCTAssertGreaterThan(IslandDropModeControl.hoverPanelHeight, 90)
        XCTAssertLessThan(IslandDropModeControl.hoverPanelHeight, 210)
        XCTAssertGreaterThan(
            IslandDropModeControl.hoverPanelHeight,
            IslandFrameLayout.defaultCompactHeight
        )
    }

    func test_hoverControlIconsAreAboutSeventyPercentLargerThanLegacySize() {
        XCTAssertEqual(IslandHoverPanelIconStyle.legacyCircleSize, 28, accuracy: 0.001)
        XCTAssertEqual(
            IslandHoverPanelIconStyle.circleSize / IslandHoverPanelIconStyle.legacyCircleSize,
            1.7,
            accuracy: 0.04
        )
        XCTAssertEqual(IslandDropModeControl.modeCircleSize, IslandHoverPanelIconStyle.circleSize)
        XCTAssertEqual(IslandLanguageControl.circleSize, IslandHoverPanelIconStyle.circleSize)
    }

    func test_detachedHoverPanelHasGapAndUniformCorners() {
        XCTAssertEqual(IslandDropModeControl.detachedPanelGap, 8, accuracy: 0.001)
        XCTAssertEqual(IslandDropModeControl.detachedPanelCornerRadius, 16, accuracy: 0.001)
        // Gap must be smaller than the panel height so the drawer still has room.
        XCTAssertLessThan(IslandDropModeControl.detachedPanelGap,
                          IslandDropModeControl.hoverPanelHeight)
    }

    func test_detachedHoverPanelGlassLetsBackgroundLightThrough() {
        // Depth wash darkens toward the bottom but must never go opaque —
        // the behind-window blur is the whole point of the glass.
        XCTAssertLessThan(
            IslandDetachedHoverPanelGlassStyle.depthWashTopOpacity,
            IslandDetachedHoverPanelGlassStyle.depthWashBottomOpacity
        )
        XCTAssertLessThan(IslandDetachedHoverPanelGlassStyle.depthWashBottomOpacity, 0.25)
        // Specular is a soft accent, not a white cap.
        XCTAssertGreaterThan(IslandDetachedHoverPanelGlassStyle.specularOpacity, 0.04)
        XCTAssertLessThan(IslandDetachedHoverPanelGlassStyle.specularOpacity, 0.2)
        // Light comes from above: both edge layers fade top -> bottom.
        XCTAssertGreaterThan(
            IslandDetachedHoverPanelGlassStyle.lensStrokeTopOpacity,
            IslandDetachedHoverPanelGlassStyle.lensStrokeBottomOpacity
        )
        XCTAssertLessThan(IslandDetachedHoverPanelGlassStyle.lensStrokeTopOpacity, 0.45)
        XCTAssertGreaterThan(
            IslandDetachedHoverPanelGlassStyle.rimTopOpacity,
            IslandDetachedHoverPanelGlassStyle.rimBottomOpacity
        )
        XCTAssertLessThan(IslandDetachedHoverPanelGlassStyle.rimTopOpacity, 0.6)
        // The lens band is wider than the crisp rim — that contrast is what
        // sells the bent-light edge.
        XCTAssertGreaterThan(
            IslandDetachedHoverPanelGlassStyle.lensStrokeWidth,
            IslandDetachedHoverPanelGlassStyle.rimWidth
        )
    }

    func test_oldIntegrationsPdfAssetIsNotBundledOrCopied() throws {
        let root = try projectRoot()
        let oldPdf = root
            .appendingPathComponent("Resources")
            .appendingPathComponent("island-integration.pdf")
        let oldSourceSvg = root
            .appendingPathComponent("svg v2")
            .appendingPathComponent("integration.svg")

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPdf.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldSourceSvg.path))

        for scriptPath in ["scripts/dev-run.sh", "scripts/build-dmg.sh"] {
            let scriptURL = root.appendingPathComponent(scriptPath)
            let script = try String(contentsOf: scriptURL, encoding: .utf8)
            XCTAssertFalse(script.contains("island-integration"))
        }
    }

    func test_languageControlUsesCompactPresentation() {
        XCTAssertEqual(IslandLanguageControl.title, "Input Language")
        XCTAssertEqual(IslandLanguageControl.systemImage, "globe")
        XCTAssertEqual(IslandLanguageControl.label(for: nil), "Auto")
        XCTAssertNil(IslandLanguageControl.hoverTileLabel(for: nil))
        XCTAssertEqual(
            IslandLanguageControl.label(for: AppLanguage.find(code: "ru")),
            AppLanguage.find(code: "ru")?.displayName
        )
        XCTAssertNil(IslandLanguageControl.hoverTileLabel(for: AppLanguage.find(code: "ru")))
    }

    func test_hoverPanelUsesGraphiteSquirclesWithMagneticPull() {
        XCTAssertEqual(IslandGraphiteHoverControlStyle.tileSize, 44, accuracy: 0.001)
        XCTAssertEqual(IslandGraphiteHoverControlStyle.iconFontSize, 18, accuracy: 0.001)
        XCTAssertEqual(IslandGraphiteHoverControlStyle.textIconFontSize, 16, accuracy: 0.001)
        XCTAssertEqual(IslandGraphiteHoverControlStyle.textIconFrameSize.width, 40, accuracy: 0.001)
        XCTAssertEqual(IslandGraphiteHoverControlStyle.textIconFrameSize.height, 25, accuracy: 0.001)
        XCTAssertEqual(IslandGraphiteHoverControlStyle.cornerRadius, 11, accuracy: 0.001)
        XCTAssertEqual(IslandGraphiteHoverControlStyle.labelTracking, 0.8, accuracy: 0.001)

        let pull = IslandGraphiteHoverControlStyle.magneticPull(
            location: CGPoint(x: 60, y: 12),
            bounds: CGSize(width: 70, height: 68)
        )

        XCTAssertGreaterThan(pull.width, 0)
        XCTAssertLessThan(abs(pull.width), IslandGraphiteHoverControlStyle.magnetStrength)
        XCTAssertLessThan(pull.height, 0)
        XCTAssertLessThan(abs(pull.height), IslandGraphiteHoverControlStyle.magnetStrength)
    }

    func test_historyHoverTileRoutesToHistoryPanel() throws {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("DynamicIsland")
            .appendingPathComponent("IslandView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("let onOpenHistory: () -> HistoryStripMode"))
        XCTAssertTrue(source.contains("onOpenHistory: actions.openHistory"))

        guard
            let historyStart = source.range(of: "title: \"History\""),
            let nextTileStart = source.range(of: "title: \"Vocab\"", range: historyStart.upperBound..<source.endIndex)
        else {
            return XCTFail("Could not find History/Vocab hover tiles in IslandView.swift")
        }

        // The History tile routes into the `.history` panel mode. The
        // paste-target + remembered-mode capture used to live in this tile
        // closure; the configurable-hotkeys feature moved it onto the
        // `panelMode -> .history` transition so the ⌥N Hover-slot hotkey enters
        // History through the SAME capture path as a click (D1). The tile now
        // only flips the mode.
        let historyTile = String(source[historyStart.lowerBound..<nextTileStart.lowerBound])
        XCTAssertTrue(historyTile.contains("panelMode = .history"))
        XCTAssertFalse(historyTile.contains("action: {}"))

        // Capture lives on the shared panelMode transition, reachable by both
        // the click and the hotkey path.
        XCTAssertTrue(source.contains("if newMode == .history"))
        XCTAssertTrue(source.contains("historyMode = onOpenHistory()"))
        XCTAssertTrue(source.contains("historyTargetAppName = historyPasteTargetName()"))
    }

    func test_hoverPanelMatchesProductionFiveSlotGrid() throws {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("DynamicIsland")
            .appendingPathComponent("IslandView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let controlSourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("DynamicIsland")
            .appendingPathComponent("IslandDropModeControl.swift")
        let controlSource = try String(contentsOf: controlSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("title: \"Case\""))
        XCTAssertTrue(source.contains("systemImage: \"key.horizontal\""))
        XCTAssertTrue(source.contains("panelMode = .caseVault"))
        XCTAssertTrue(source.contains("title: \"Hotkeys\""))
        XCTAssertTrue(source.contains("systemImage: \"keyboard\""))
        // The Hotkeys/Notes/Quit tile actions are wrapped to also emit an
        // island_control_click before invoking the original handler (Analytics
        // Batch 2, M4); assert the handler is still invoked from the action.
        XCTAssertTrue(source.contains("onOpenHotkeys()"))
        XCTAssertTrue(source.contains("title: \"Filler\""))
        XCTAssertTrue(source.contains("title: IslandLanguageControl.title"))
        XCTAssertTrue(source.contains("title: IslandOutputLanguageControl.title"))
        XCTAssertTrue(source.contains("title: \"Notes\""))
        XCTAssertTrue(source.contains("systemImage: \"note.text\""))
        XCTAssertTrue(source.contains("onOpenNotes()"))
        XCTAssertTrue(source.contains("title: \"Quit\""))
        XCTAssertTrue(source.contains("accessibilityLabel: \"Quit Whytap\""))
        XCTAssertTrue(source.contains("onQuit()"))
        XCTAssertFalse(source.contains("title: \"Exit\""))
        XCTAssertTrue(source.contains("static let tileWidth: CGFloat = 55"))
        XCTAssertTrue(source.contains("static let tileHeight: CGFloat = 72"))
        XCTAssertTrue(source.contains(".frame(width: Self.tileWidth, height: Self.tileHeight, alignment: .center)"))
        XCTAssertTrue(source.contains("private static let tileSpacing: CGFloat = 2"))
        XCTAssertTrue(controlSource.contains("static let compactCircleSize: CGFloat = 34"))
    }

    func test_languageTextBadgeKeepsMagneticPullButUsesStableRendering() {
        let location = CGPoint(x: 48, y: 21)
        let bounds = CGSize(width: 70, height: 68)
        let rawPull = IslandGraphiteHoverControlStyle.magneticPull(
            location: location,
            bounds: bounds
        )
        let textPull = IslandGraphiteHoverControlStyle.magneticPull(
            location: location,
            bounds: bounds,
            presentation: .text("RU")
        )
        let symbolPull = IslandGraphiteHoverControlStyle.magneticPull(
            location: location,
            bounds: bounds,
            presentation: .systemImage("globe")
        )

        XCTAssertNotEqual(rawPull, .zero)
        XCTAssertEqual(textPull, rawPull)
        XCTAssertEqual(symbolPull, rawPull)
        XCTAssertTrue(IslandGraphiteHoverControlStyle.textIconUsesOffscreenRendering)
    }

    func test_languageHoverIconUsesPlanetForAutoAndIsoLettersForSelectedLanguage() {
        XCTAssertEqual(
            IslandLanguageControl.hoverIconPresentation(for: nil),
            .systemImage("globe")
        )
        XCTAssertEqual(
            IslandLanguageControl.hoverIconPresentation(for: AppLanguage.find(code: "ru")),
            .text("RU")
        )
        XCTAssertEqual(
            IslandLanguageControl.hoverIconPresentation(for: AppLanguage.find(code: "en")),
            .text("EN")
        )
    }

    func test_languageRingOnlyPdfExistsAndIsCopiedByBuildScripts() throws {
        let root = try projectRoot()
        let resource = root
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(IslandLanguageControl.ringOnlyPdfResource).pdf")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: resource.path),
            "Missing \(IslandLanguageControl.ringOnlyPdfResource).pdf in Resources/"
        )

        for scriptPath in ["scripts/dev-run.sh", "scripts/build-dmg.sh"] {
            let scriptURL = root.appendingPathComponent(scriptPath)
            let script = try String(contentsOf: scriptURL, encoding: .utf8)
            XCTAssertTrue(
                script.contains(IslandLanguageControl.ringOnlyPdfResource),
                "\(scriptPath) must copy \(IslandLanguageControl.ringOnlyPdfResource).pdf into the app bundle"
            )
        }
    }

    func test_hoverPdfAssetsUseHighResolutionFilterRasters() throws {
        let root = try projectRoot()
        let pdfResources = [
            IslandDropModeControl.pdfResource(for: .fast),
            IslandDropModeControl.pdfResource(for: .smart),
            IslandLanguageControl.pdfResource,
            IslandLanguageControl.ringOnlyPdfResource,
            "island-clipboard",
            "island-vocab",
            "island-settings",
            "island-exit",
        ]

        for resource in pdfResources {
            let url = root
                .appendingPathComponent("Resources")
                .appendingPathComponent("\(resource).pdf")
            let data = try Data(contentsOf: url)
            let widths = pdfRasterWidths(in: data)

            XCTAssertFalse(
                widths.contains { $0 <= 96 },
                "\(resource).pdf still contains low-resolution raster layers: \(widths)"
            )
            XCTAssertTrue(
                widths.isEmpty || (widths.max() ?? 0) >= 300,
                "\(resource).pdf should be rebuilt with high-resolution filter rasters, got \(widths)"
            )
        }
    }

    func test_languageOptionsIncludeAutoAndSupportedLanguages() {
        let options = IslandLanguageControl.options()

        XCTAssertNil(options.first?.language)
        XCTAssertEqual(options.first?.label, "Auto")
        XCTAssertEqual(options.first?.flag, "auto")
        XCTAssertEqual(options.dropFirst().map(\.language), AppLanguage.all.map(Optional.some))
    }

    func test_languagePickerOptionsDeduplicateSharedCountryFlags() {
        let options = IslandLanguageControl.pickerOptions()
        let languageOptions = options.filter { $0.language != nil }
        let countryCodes = languageOptions.compactMap(\.countryCode)
        let spain = try! XCTUnwrap(languageOptions.first { $0.countryCode == "ES" })
        let india = try! XCTUnwrap(languageOptions.first { $0.countryCode == "IN" })

        XCTAssertEqual(options.first?.id, IslandLanguageControl.autoOptionID)
        XCTAssertEqual(Set(countryCodes).count, countryCodes.count)
        XCTAssertEqual(spain.language?.code, "es")
        XCTAssertTrue(spain.variantLanguages.map(\.code).contains("ca"))
        XCTAssertEqual(india.language?.code, "hi")
        XCTAssertTrue(india.variantLanguages.map(\.code).contains("gu"))
        XCTAssertTrue(india.variantLanguages.map(\.code).contains("ta"))
    }

    func test_languagePickerOptionsPreferSelectedLanguageWithinSharedCountryFlag() {
        let hindi = try! XCTUnwrap(AppLanguage.find(code: "hi"))
        let gujarati = try! XCTUnwrap(AppLanguage.find(code: "gu"))

        let hindiGroup = try! XCTUnwrap(
            IslandLanguageControl.pickerOptions(selectedLanguage: hindi)
                .first { $0.countryCode == "IN" }
        )
        let gujaratiGroup = try! XCTUnwrap(
            IslandLanguageControl.pickerOptions(selectedLanguage: gujarati)
                .first { $0.countryCode == "IN" }
        )

        XCTAssertEqual(hindiGroup.language?.code, hindi.code)
        XCTAssertEqual(gujaratiGroup.language?.code, gujarati.code)
    }

    func test_languagePickerUsesAmericanFlagForEnglishButKeepsBackendCode() {
        let english = try! XCTUnwrap(AppLanguage.find(code: "en"))
        let option = try! XCTUnwrap(
            IslandLanguageControl.pickerOptions()
                .first { $0.language?.code == "en" }
        )

        XCTAssertEqual(IslandLanguageControl.countryCode(forLanguageCode: english.code), "US")
        XCTAssertEqual(option.countryCode, "US")
        XCTAssertEqual(option.flag, IslandLanguageControl.flag(forCountryCode: "US"))
        XCTAssertEqual(option.language?.code, "en")
    }

    func test_languageFilteringMatchesEnglishDisplayNameAndCode() {
        XCTAssertEqual(
            IslandLanguageControl.filteredOptions(query: "span").map(\.language?.code),
            ["es"]
        )
        XCTAssertEqual(
            IslandLanguageControl.filteredOptions(query: "deu").map(\.language?.code),
            ["de"]
        )
        XCTAssertEqual(
            IslandLanguageControl.filteredOptions(query: "pt").map(\.language?.code),
            ["pt"]
        )
    }

    func test_languageFilteringHidesAutoUnlessItMatchesQuery() {
        XCTAssertEqual(
            IslandLanguageControl.filteredOptions(query: "auto").map(\.id),
            [IslandLanguageControl.autoOptionID]
        )
        XCTAssertFalse(
            IslandLanguageControl.filteredOptions(query: "rus").contains {
                $0.id == IslandLanguageControl.autoOptionID
            }
        )
    }

    func test_languageFlagUsesMappedCountryCode() {
        XCTAssertEqual(IslandLanguageControl.countryCode(forLanguageCode: "en"), "US")
        XCTAssertEqual(IslandLanguageControl.countryCode(forLanguageCode: "zh"), "CN")

        let flag = IslandLanguageControl.flag(forCountryCode: "US")
        XCTAssertEqual(flag.unicodeScalars.map(\.value), [127482, 127480])
    }

    func test_languageFlagAssetsUseBundledPngNamesForCountryCodes() {
        XCTAssertEqual(
            IslandLanguageControl.flagAssetResourceName(forCountryCode: "US"),
            "flag_us"
        )
        XCTAssertEqual(
            IslandLanguageControl.flagAssetResourceName(forCountryCode: "ru"),
            "flag_ru"
        )
    }

    // Removed test_languagePickerCountryFlagsHaveBundledPngAssets: the Island
    // now renders emoji flags for every country (the ~99-language set spans
    // far more countries than the ~44 bundled PNGs), so per-country PNG
    // coverage is no longer required.

    func test_languageFlagAssetsAreCopiedByDevAndProductionBuildScripts() throws {
        let root = try projectRoot()
        for scriptPath in ["scripts/dev-run.sh", "scripts/build-dmg.sh"] {
            let scriptURL = root.appendingPathComponent(scriptPath)
            let script = try String(contentsOf: scriptURL, encoding: .utf8)
            XCTAssertTrue(
                script.contains("LanguageFlags"),
                "\(scriptPath) must copy Resources/LanguageFlags into the app bundle"
            )
        }
    }

    func test_languagePickerInputIsTopCenteredAboveFlags() {
        let panelSize = CGSize(width: 312, height: IslandDropModeControl.hoverPanelHeight)
        let optionCount = IslandLanguageControl.pickerOptions().count
        let inputFrame = IslandLanguagePickerLayout.inputFrame(
            panelSize: panelSize,
            optionCount: optionCount
        )
        let flagFrames = IslandLanguagePickerLayout.flagFrames(
            panelSize: panelSize,
            count: optionCount
        )
        let firstLanguageFlagY = try! XCTUnwrap(flagFrames.dropFirst().map(\.minY).min())

        XCTAssertEqual(inputFrame.midX, panelSize.width / 2, accuracy: 0.001)
        XCTAssertLessThan(inputFrame.midY, panelSize.height / 2)
        XCTAssertLessThan(inputFrame.maxY, firstLanguageFlagY)
    }

    func test_languagePickerPlacesAutoNextToInputAndUniqueFlagsInFourRowsBelowInput() {
        let panelSize = CGSize(width: 328, height: IslandDropModeControl.hoverPanelHeight)
        let options = IslandLanguageControl.pickerOptions()
        let optionCount = options.count
        let inputFrame = IslandLanguagePickerLayout.inputFrame(
            panelSize: panelSize,
            optionCount: optionCount
        )
        let flagFrames = IslandLanguagePickerLayout.flagFrames(
            panelSize: panelSize,
            count: optionCount
        )
        let autoFrame = try! XCTUnwrap(flagFrames.first)
        let languageFrames = Array(flagFrames.dropFirst())
        let rowYValues = Array(Set(languageFrames.map(\.minY))).sorted()
        let bottomRowY = try! XCTUnwrap(rowYValues.last)

        XCTAssertEqual(options.first?.id, IslandLanguageControl.autoOptionID)
        XCTAssertEqual(flagFrames.count, optionCount)
        XCTAssertGreaterThan(autoFrame.width, IslandLanguagePickerLayout.flagChipSize.width)
        XCTAssertEqual(autoFrame.midY, inputFrame.midY, accuracy: 0.001)
        XCTAssertLessThan(autoFrame.maxX, inputFrame.minX)
        XCTAssertEqual(rowYValues.count, 4)
        XCTAssertTrue(rowYValues.allSatisfy { $0 > inputFrame.maxY })
        XCTAssertEqual(
            bottomRowY + IslandLanguagePickerLayout.flagChipSize.height,
            panelSize.height - IslandLanguagePickerLayout.edgeInset,
            accuracy: 0.001
        )
    }

    func test_languagePickerBalancesFlagsAcrossRowsInsteadOfLeavingSparseLastRow() {
        let panelSize = CGSize(width: 328, height: IslandDropModeControl.hoverPanelHeight)
        let flagFrames = IslandLanguagePickerLayout.flagFrames(
            panelSize: panelSize,
            count: IslandLanguageControl.pickerOptions().count
        )
        let rowCounts = Dictionary(grouping: flagFrames.dropFirst()) { $0.minY }
            .values
            .map(\.count)

        let minRowCount = try! XCTUnwrap(rowCounts.min())
        let maxRowCount = try! XCTUnwrap(rowCounts.max())

        XCTAssertLessThanOrEqual(maxRowCount - minRowCount, 1)
    }

    func test_languageVariantFramesStayCenteredInsteadOfAnchoringToPanelEdges() {
        let panelSize = CGSize(width: 328, height: IslandDropModeControl.hoverPanelHeight)
        let frames = IslandLanguagePickerLayout.variantFrames(
            panelSize: panelSize,
            count: 2
        )

        XCTAssertEqual(frames.count, 2)
        XCTAssertGreaterThan(frames[0].minX, IslandLanguagePickerLayout.edgeInset + 40)
        XCTAssertLessThan(frames[1].maxX, panelSize.width - IslandLanguagePickerLayout.edgeInset - 40)
    }

    func test_languageVariantFramesShrinkToFitSevenVariantsIntoOneBalancedRow() {
        let panelSize = CGSize(width: 328, height: IslandDropModeControl.hoverPanelHeight)
        let frames = IslandLanguagePickerLayout.variantFrames(
            panelSize: panelSize,
            count: 7
        )
        let rowYValues = Set(frames.map(\.minY))

        XCTAssertEqual(frames.count, 7)
        XCTAssertEqual(rowYValues.count, 1)
        XCTAssertLessThan(frames[0].width, IslandLanguagePickerLayout.variantChipSize.width)
        XCTAssertGreaterThan(frames[0].width, 36)
    }

    func test_languagePickerFilteredResultsUseLargeTargetsBelowTopInput() {
        let panelSize = CGSize(width: 328, height: IslandDropModeControl.hoverPanelHeight)
        let inputFrame = IslandLanguagePickerLayout.inputFrame(
            panelSize: panelSize,
            optionCount: 2,
            anchorsToFullGrid: false
        )
        let flagFrames = IslandLanguagePickerLayout.flagFrames(
            panelSize: panelSize,
            count: 2,
            anchorsToFullGrid: false
        )

        XCTAssertEqual(flagFrames.count, 2)
        XCTAssertGreaterThan(
            IslandLanguagePickerLayout.filteredFlagChipSize.width,
            IslandLanguagePickerLayout.flagChipSize.width
        )
        XCTAssertGreaterThan(flagFrames[0].width, IslandLanguagePickerLayout.flagChipSize.width)
        XCTAssertTrue(flagFrames.allSatisfy { $0.minY > inputFrame.maxY })
        XCTAssertGreaterThan(flagFrames[0].minX, IslandLanguagePickerLayout.edgeInset)
        XCTAssertLessThan(flagFrames[1].maxX, panelSize.width - IslandLanguagePickerLayout.edgeInset)
    }

    func test_languagePlaceholderSamplesUseNativeLanguageNames() {
        XCTAssertTrue(IslandLanguageControl.placeholderSamples.contains("English"))
        XCTAssertTrue(IslandLanguageControl.placeholderSamples.contains("Русский"))
        XCTAssertTrue(IslandLanguageControl.placeholderSamples.contains("中文"))
        XCTAssertFalse(IslandLanguageControl.placeholderSamples.contains("language"))
    }

    func test_languagePlaceholderTypesAndCyclesThroughNativeNames() {
        let samples = IslandLanguageControl.placeholderSamples
        let first = try! XCTUnwrap(samples.first)
        let second = try! XCTUnwrap(samples.dropFirst().first)

        XCTAssertEqual(IslandLanguageControl.placeholder(at: 0), String(first.prefix(1)))
        XCTAssertEqual(
            IslandLanguageControl.placeholder(
                at: IslandLanguageControl.placeholderIntervalSeconds * 0.8
            ),
            first
        )
        XCTAssertEqual(
            IslandLanguageControl.placeholder(
                at: IslandLanguageControl.placeholderIntervalSeconds
            ),
            String(second.prefix(1))
        )
    }

    func test_languageFlagChromeOnlyWrapsAutoOption() {
        let options = IslandLanguageControl.options()
        let auto = try! XCTUnwrap(options.first)
        let english = try! XCTUnwrap(options.first { $0.language?.code == "en" })

        XCTAssertTrue(IslandLanguageFlagChipStyle.usesCapsuleChrome(for: auto))
        XCTAssertFalse(IslandLanguageFlagChipStyle.usesCapsuleChrome(for: english))
    }

    func test_languageFlagHoverScaleGrowsPlainFlags() {
        let english = try! XCTUnwrap(
            IslandLanguageControl.options().first { $0.language?.code == "en" }
        )

        XCTAssertGreaterThan(IslandLanguageFlagChipStyle.hoverScale(for: english), 1)
    }

    func test_languagePickerFlagsGrowWithTwoRowHoverPanel() {
        XCTAssertGreaterThanOrEqual(IslandLanguagePickerLayout.flagChipSize.width, 22)
        XCTAssertGreaterThanOrEqual(IslandLanguagePickerLayout.flagChipSize.height, 18)
        XCTAssertGreaterThanOrEqual(IslandLanguageFlagChipStyle.languageFontSize, 22)
        XCTAssertGreaterThanOrEqual(IslandLanguagePickerLayout.filteredFlagChipSize.width, 32)
        XCTAssertGreaterThanOrEqual(IslandLanguageFlagChipStyle.filteredLanguageFontSize, 24)
    }

    func test_languagePickerUsesMoreRowsWhenHoverPanelIsTall() {
        let panelSize = CGSize(width: 328, height: IslandDropModeControl.hoverPanelHeight)
        let flagFrames = IslandLanguagePickerLayout.flagFrames(
            panelSize: panelSize,
            count: IslandLanguageControl.pickerOptions().count
        )
        let distinctRows = Set(flagFrames.dropFirst().map { Int(round($0.minY)) })

        XCTAssertEqual(distinctRows.count, 4)
    }

    func test_languagePickerRowsUseEvenVerticalRhythmBelowInput() {
        let panelSize = CGSize(width: 328, height: IslandDropModeControl.hoverPanelHeight)
        let flagFrames = IslandLanguagePickerLayout.flagFrames(
            panelSize: panelSize,
            count: IslandLanguageControl.pickerOptions().count
        )
        let rowYValues = Array(Set(flagFrames.dropFirst().map(\.minY))).sorted()
        let inputFrame = IslandLanguagePickerLayout.inputFrame(
            panelSize: panelSize,
            optionCount: IslandLanguageControl.pickerOptions().count
        )

        XCTAssertEqual(rowYValues.count, 4)
        XCTAssertGreaterThan(try! XCTUnwrap(rowYValues.first), inputFrame.maxY)

        let strides = zip(rowYValues, rowYValues.dropFirst()).map { $1 - $0 }
        let firstStride = try! XCTUnwrap(strides.first)
        for stride in strides {
            XCTAssertEqual(stride, firstStride, accuracy: 0.001)
        }
    }

    func test_languageInputCursorUsesThinGrayVerticalStyle() {
        XCTAssertLessThan(IslandLanguageInputStyle.cursorWidth, 1)
        XCTAssertGreaterThan(IslandLanguageInputStyle.cursorWidth, 0.4)
        XCTAssertLessThan(IslandLanguageInputStyle.cursorWhiteComponent, 0.8)
        XCTAssertGreaterThan(IslandLanguageInputStyle.cursorWhiteComponent, 0.4)
        XCTAssertLessThanOrEqual(IslandLanguageInputStyle.cursorAlpha, 1)
    }

    func test_meetingSuggestionBlocksHoverExpansion() {
        XCTAssertTrue(IslandHoverPolicy.allowsExpansion(meetingSuggestionActive: false))
        XCTAssertFalse(IslandHoverPolicy.allowsExpansion(meetingSuggestionActive: true))
        // Recording an active meeting is allowed; only the short
        // suggestion window blocks expansion. See
        // `IslandHoverPolicyTests.test_allowsExpansion_notBlockedWhenMeetingRecording`.
        XCTAssertTrue(IslandHoverPolicy.allowsExpansion(
            meetingSuggestionActive: false,
            meetingRecordingActive: true
        ))
    }

    func test_meetingCountdownComputesRemainingSecondsAndRingProgress() {
        let now = Date(timeIntervalSince1970: 100)
        let deadline = now.addingTimeInterval(12.2)

        XCTAssertEqual(IslandMeetingCountdown.remainingSeconds(now: now, deadline: deadline), 13)
        XCTAssertEqual(
            IslandMeetingCountdown.remainingSeconds(
                now: deadline.addingTimeInterval(1),
                deadline: deadline
            ),
            0
        )
        XCTAssertEqual(
            IslandMeetingCountdown.progress(
                now: now,
                deadline: deadline,
                duration: 20
            ),
            0.61,
            accuracy: 0.001
        )
    }

    func test_meetingCountdownFitsInsideRightBand() {
        let size = IslandMeetingCountdown.circleSize(forCompactHeight: 38)

        XCTAssertGreaterThan(size, 20)
        XCTAssertLessThanOrEqual(size, 26)
        XCTAssertLessThanOrEqual(size, IslandFrameLayout.rightSideWidth)
    }

    func test_meetingRecordingSlotFitsRightBandAndNormalizesVoiceWave() {
        let levels = IslandMeetingRecordingSlot.appendingLevel(
            to: [0.1, 0.2],
            level: 1.4
        )

        XCTAssertEqual(IslandMeetingRecordingSlot.barCount, 12)
        XCTAssertLessThanOrEqual(
            IslandMeetingRecordingSlot.width,
            IslandFrameLayout.rightSideWidth
        )
        XCTAssertEqual(levels.count, IslandMeetingRecordingSlot.barCount)
        XCTAssertEqual(levels.last ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(IslandMeetingRecordingSlot.formattedElapsed(74.9), "01:14")
        XCTAssertEqual(IslandMeetingRecordingSlot.formattedElapsed(3_661), "1:01")
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "IslandDropModeControlTests", code: 1)
    }

    private func pdfRasterWidths(in data: Data) -> [Int] {
        let text = String(decoding: data, as: UTF8.self)
        let pattern = #"/Subtype /Image[\s\S]*?/Width\s+([0-9]+)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        return regex.matches(in: text, range: range).compactMap { match in
            guard let widthRange = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[widthRange])
        }
    }
}
