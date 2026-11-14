import AppKit
import DazzleEngine

/// The Format tab: text, fill, outline, effects, arrangement and the
/// like for the selected objects; with nothing selected, the slide's
/// background and timing, and the presentation's size.
extension InspectorViewController {
    func buildFormat() {
        guard let slide = deck.selectedSlide else { return }
        guard let shape = deck.selectedShape else { return buildSlide(slide) }
        guard shape.isEditable, slide.canEditShapes else {
            form.section(shape.name)
            form.note(String(localized: "Format.Locked"))
            return
        }
        if shape.canHoldText || state.isEditingCell { buildText() }
        if !shape.isPicture, case .shape = shape.kind, !PresetGeometry.isOpen(shape.geometry.presetName ?? "") {
            buildFill(of: shape)
        }
        if case .table(let table) = shape.kind { buildTable(table) }
        if case .chart(let chart?) = shape.kind, !state.hasMultipleSelection { buildChart(chart) }
        if case .picture(let picture) = shape.kind, !state.hasMultipleSelection {
            buildPicture()
            if let media = picture.media { buildPlayback(kind: media.kind) }
        }
        switch shape.kind {
        case .shape, .connector, .picture:
            buildOutline(of: shape)
            buildEffects()
        default:
            break
        }
        buildArrange(shape)
        if !state.hasMultipleSelection {
            if state.editingTextShapeID == shape.id || state.isEditingCell {
                buildLink(
                    footer: String(localized: (state.textSelection?.length ?? 0) > 0 ? "Format.Link.Selection" : "Format.Link.AllText"),
                    get: { [unowned self] in run.link },
                    set: { [unowned self] link in edit { state.setTextLink(link, in: &$0) } }
                )
            } else {
                buildLink(
                    footer: String(localized: "Format.Link.Footer"),
                    get: { [unowned self] in deck.selectedShape?.link },
                    set: { [unowned self] link in edit { state.setShapeLink(link, in: &$0) } }
                )
            }
            buildDescription()
        }
    }

    // MARK: - Links

    /// Where a link goes: a web address, a slide, or a step through the show.
    private func buildLink(footer: String, get: @escaping () -> Hyperlink?, set: @escaping (Hyperlink?) -> Void) {
        form.section(String(localized: "Format.Section.Link"))
        var kinds: [(String.LocalizationValue, (Presentation) -> Hyperlink?)] = [
            ("Link.None", { _ in nil }), ("Link.URL", { _ in .url("https://") }),
            ("Link.Slide", { $0.slides.first.map { .slide($0.id) } }), ("Link.Next", { _ in .nextSlide }),
            ("Link.Previous", { _ in .previousSlide }), ("Link.First", { _ in .firstSlide }),
            ("Link.Last", { _ in .lastSlide }), ("Link.End", { _ in .endShow }),
        ]
        if !deck.presentation.customShows.isEmpty || get()?.isCustomShow == true {
            kinds.append(("Link.CustomShow", { $0.customShows.first.map { .customShow($0.id, returns: true) } }))
        }
        func index(of link: Hyperlink?) -> Int? {
            switch link {
            case nil: 0
            case .url?: 1
            case .slide?, .slidePart?: 2
            case .nextSlide?: 3
            case .previousSlide?: 4
            case .firstSlide?: 5
            case .lastSlide?: 6
            case .endShow?: 7
            case .customShow?: 8
            case .other?: nil
            }
        }
        form.row(String(localized: "Link.Kind"), form.popup(kinds.map { String(localized: $0.0) }, get: {
            index(of: get())
        }, set: { [unowned self] chosen in
            set(kinds[chosen].1(deck.presentation))
        }))

        let address = form.text(placeholder: String(localized: "Link.URL.Placeholder"), get: {
            if case .url(let address)? = get() { return address }
            return ""
        }, set: { text in
            set(.url(Hyperlink.normalizedAddress(text)))
        })
        form.row(nil, address)

        let slides = NSPopUpButton()
        let slideTarget = ActionTarget { [unowned self] in
            let index = slides.indexOfSelectedItem
            guard deck.presentation.slides.indices.contains(index) else { return }
            set(.slide(deck.presentation.slides[index].id))
        }
        slides.target = slideTarget
        slides.action = #selector(ActionTarget.run(_:))
        form.row(nil, slides)

        let shows = NSPopUpButton()
        shows.setAccessibilityIdentifier("linkCustomShow")
        let showTarget = ActionTarget { [unowned self] in
            guard case .customShow(_, let returns)? = get(), let id = shows.selectedItem?.tag else { return }
            set(.customShow(id, returns: returns))
        }
        shows.target = showTarget
        shows.action = #selector(ActionTarget.run(_:))
        form.row(nil, shows)
        let returns = form.checkbox(String(localized: "Link.CustomShow.Return"), get: {
            if case .customShow(_, true)? = get() { return true }
            return false
        }, set: { isOn in
            guard case .customShow(let id, _)? = get() else { return }
            set(.customShow(id, returns: isOn))
        })
        form.row(nil, returns)
        form.note(footer)
        form.onUpdate { [unowned self] in
            _ = slideTarget
            _ = showTarget
            let link = get()
            if case .url? = link { address.isHidden = false } else { address.isHidden = true }
            if case .customShow(let id, _)? = link {
                shows.isHidden = false
                returns.isHidden = false
                shows.removeAllItems()
                for show in deck.presentation.customShows {
                    shows.addItem(withTitle: show.name)
                    shows.lastItem?.tag = show.id
                }
                if deck.presentation.customShow(withID: id) == nil {
                    shows.addItem(withTitle: String(localized: "Link.CustomShow.Missing"))
                    shows.lastItem?.tag = id
                }
                shows.selectItem(withTag: id)
            } else {
                shows.isHidden = true
                returns.isHidden = true
            }
            guard case .slide(let id)? = link else {
                slides.isHidden = true
                return
            }
            slides.isHidden = false
            let presentation = deck.presentation
            slides.removeAllItems()
            slides.addItems(withTitles: presentation.slides.enumerated().map { index, slide in
                "\(index + 1). \(slide.title ?? String(localized: "Slide.Untitled"))"
            })
            if let index = presentation.index(of: id) { slides.selectItem(at: index) }
        }
    }

    // MARK: - Text

    private var run: RunProperties { state.effectiveRunProperties(in: deck.presentation) }
    private var paragraph: ParagraphProperties { state.effectiveParagraphProperties(in: deck.presentation) }

    private func buildText() {
        form.section(String(localized: "Format.Section.Text"))
        let theme = style?.theme
        let families = NSFontManager.shared.availableFontFamilies
        var values = ["+mj-lt", "+mn-lt"]
        var titles = [
            String(format: String(localized: "Format.Font.Headings"), theme?.majorFont ?? ""),
            String(format: String(localized: "Format.Font.Body"), theme?.minorFont ?? ""),
        ]
        if let current = run.latinFont, !current.hasPrefix("+"), !families.contains(current) {
            values.append(current)
            titles.append(current)
        }
        values += families
        titles += families
        let fonts = form.popup(titles, get: { [unowned self] in
            let font = run.latinFont ?? "+mn-lt"
            return values.firstIndex(of: font == "+mj-ea" ? "+mj-lt" : font == "+mn-ea" ? "+mn-lt" : font)
        }, set: { [unowned self] index in
            let family = values[index]
            edit { state.setFontFamily(family, in: &$0) }
        })
        form.row(nil, fonts)

        form.row(String(localized: "Format.Text.Size"), form.number(get: { [unowned self] in
            Double(run.size ?? 1_800) / 100
        }, set: { [unowned self] value in
            let current = Double(run.size ?? 1_800) / 100
            edit { state.stepFontSize(by: Int((value - current).rounded()), in: &$0) }
        }, range: 6...400, step: 1, unit: "pt"))

        let styles = form.toggles([
            ("bold", String(localized: "Format.Bold")), ("italic", String(localized: "Format.Italic")),
            ("underline", String(localized: "Format.Underline")), ("strikethrough", String(localized: "Format.Strikethrough")),
        ], get: { [unowned self] in
            [run.isBold == true, run.isItalic == true, run.isUnderlined == true, run.isStruckThrough == true]
        }, toggle: { [unowned self] index in
            switch index {
            case 0: edit { state.toggleBold(in: &$0) }
            case 1: edit { state.toggleItalic(in: &$0) }
            case 2: edit { state.toggleUnderline(in: &$0) }
            default: edit { state.toggleStrikethrough(in: &$0) }
            }
        })
        form.row(nil, styles)

        form.row(String(localized: "Format.Section.TextColor"), form.color(
            choices: colorChoices, resolve: { [unowned self] in resolve($0) },
            get: { [unowned self] in (run.color, false) },
            set: { [unowned self] color in if let color { edit { state.setTextColor(color, in: &$0) } } }
        ))

        let alignments = ParagraphAlignment.allCases
        form.row(nil, form.choice([
            ("text.alignleft", String(localized: "Menu.Format.AlignLeft")), ("text.aligncenter", String(localized: "Menu.Format.Centre")),
            ("text.alignright", String(localized: "Menu.Format.AlignRight")), ("text.justify", String(localized: "Menu.Format.Justify")),
        ], get: { [unowned self] in
            alignments.firstIndex(of: state.effectiveAlignment(in: deck.presentation))
        }, set: { [unowned self] index in
            guard alignments.indices.contains(index) else { return }
            edit { state.setAlignment(alignments[index], in: &$0) }
        }))

        let lists: [EditorState.ListStyleChoice] = [.none, .bullets, .numbers]
        let list = form.popup(
            [String(localized: "Format.List.None"), String(localized: "Format.List.Bullets"), String(localized: "Format.List.Numbers")],
            get: { [unowned self] in lists.firstIndex(of: state.listStyle(in: deck.presentation)) },
            set: { [unowned self] index in edit { state.setListStyle(lists[index], in: &$0) } }
        )
        let indent = form.actions([
            ("decrease.indent", String(localized: "Format.Outdent")), ("increase.indent", String(localized: "Format.Indent")),
        ]) { [unowned self] index in
            edit { state.changeIndent(by: index == 0 ? -1 : 1, in: &$0) }
        }
        list.setContentHuggingPriority(.init(1), for: .horizontal)
        indent.setContentHuggingPriority(.required, for: .horizontal)
        let listRow = NSStackView(views: [list, indent])
        listRow.distribution = .fill
        listRow.spacing = 6
        form.row(String(localized: "Format.List"), listRow)

        let spacings = [1.0, 1.15, 1.5, 2.0, 2.5, 3.0]
        form.row(String(localized: "Format.LineSpacing"), form.popup(
            spacings.map { $0.formatted(.number.precision(.fractionLength(0...2))) },
            get: { [unowned self] in
                guard case .percent(let value) = paragraph.lineSpacing else { return 0 }
                return spacings.indices.min { abs(spacings[$0] - value) < abs(spacings[$1] - value) }
            },
            set: { [unowned self] index in edit { state.setLineSpacing(spacings[index], in: &$0) } }
        ))
    }

    // MARK: - Fill and outline

    private func buildFill(of shape: SlideShape) {
        form.section(String(localized: "Format.Section.Fill"))
        form.row(String(localized: "Fill.Kind"), form.color(
            choices: colorChoices, noneTitle: String(localized: "Fill.None"), resolve: { [unowned self] in resolve($0) },
            get: { [unowned self] in
                guard let shape = deck.selectedShape else { return (nil, false) }
                switch shape.fill ?? inheritedFill(of: shape) {
                case .solid(let color): return (color, false)
                case Fill.none?: return (nil, true)
                default: return (nil, false)
                }
            },
            set: { [unowned self] color in edit { state.setFill(color.map(Fill.solid) ?? Fill.none, in: &$0) } }
        ))
    }

    /// The fill a shape with none of its own gets from its style or layout.
    private func inheritedFill(of shape: SlideShape) -> Fill? {
        guard let style else { return nil }
        return style.fill(for: shape, sources: style.sources(for: shape))?.fill
    }

    private func buildOutline(of shape: SlideShape) {
        form.section(String(localized: "Format.Section.Outline"))
        form.row(String(localized: "Mac.Inspector.Colour"), form.color(
            choices: colorChoices, noneTitle: String(localized: "Fill.None"), resolve: { [unowned self] in resolve($0) },
            get: { [unowned self] in
                switch deck.selectedShape?.line?.fill {
                case .solid(let color): return (color, false)
                case Fill.none?: return (nil, true)
                default: return (nil, false)
                }
            },
            set: { [unowned self] color in edit { state.setLine({ $0.fill = color.map(Fill.solid) ?? Fill.none }, in: &$0) } }
        ))
        form.row(String(localized: "Format.Outline.Width"), form.number(get: { [unowned self] in
            EMU.points(deck.selectedShape?.line?.width ?? 12_700)
        }, set: { [unowned self] value in
            edit { state.setLine({ $0.width = EMU.from(points: max(value, 0.25)) }, in: &$0) }
        }, range: 0.25...24, step: 0.25, unit: "pt"))
        let dashes = FormatChoices.dashes
        form.row(String(localized: "Format.Outline.Dash"), form.popup(dashes.map(\.1), get: { [unowned self] in
            dashes.firstIndex { $0.0 == (deck.selectedShape?.line?.dash ?? "solid") }
        }, set: { [unowned self] index in
            let dash = dashes[index].0
            edit { state.setLine({ $0.dash = dash }, in: &$0) }
        }))
        // Arrowheads only show on lines that have ends.
        guard shape.kind == .connector || PresetGeometry.isOpen(shape.geometry.presetName ?? "") else { return }
        let ends = FormatChoices.lineEnds
        form.row(String(localized: "Format.Outline.Start"), form.popup(ends.map(\.1), get: { [unowned self] in
            ends.firstIndex { $0.0 == (deck.selectedShape?.line?.head ?? "none") }
        }, set: { [unowned self] index in
            let head = ends[index].0
            edit { state.setLine({ $0.head = head == "none" ? nil : head }, in: &$0) }
        }))
        form.row(String(localized: "Format.Outline.End"), form.popup(ends.map(\.1), get: { [unowned self] in
            ends.firstIndex { $0.0 == (deck.selectedShape?.line?.tail ?? "none") }
        }, set: { [unowned self] index in
            let tail = ends[index].0
            edit { state.setLine({ $0.tail = tail == "none" ? nil : tail }, in: &$0) }
        }))
    }

    private func buildEffects() {
        form.section(String(localized: "Mac.Inspector.Effects"))
        let shadows = FormatChoices.shadows
        form.row(String(localized: "Format.Shadow"), form.popup(
            shadows.map(\.label) + [String(localized: "Shadow.Custom")],
            get: { [unowned self] in
                let shadow = deck.selectedShape?.shadow
                return shadows.firstIndex { $0.shadow == shadow } ?? (shadow == nil ? 0 : shadows.count)
            },
            set: { [unowned self] index in
                guard shadows.indices.contains(index) else { return }
                edit { state.setShadow(shadows[index].shadow, in: &$0) }
            }
        ))
        let reflections = FormatChoices.reflections
        form.row(String(localized: "Format.Reflection"), form.popup(
            reflections.map(\.label) + [String(localized: "Reflection.Custom")],
            get: { [unowned self] in
                let reflection = deck.selectedShape?.reflection
                return reflections.firstIndex { $0.reflection == reflection } ?? (reflection == nil ? 0 : reflections.count)
            },
            set: { [unowned self] index in
                guard reflections.indices.contains(index) else { return }
                edit { state.setReflection(reflections[index].reflection, in: &$0) }
            }
        ))
    }

    // MARK: - Tables and pictures

    private func buildTable(_ table: SlideTable) {
        form.section(String(localized: "Format.Section.Table"))
        for option in SlideTable.StyleOption.allCases {
            form.row(nil, form.checkbox(option.label, get: { [unowned self] in
                state.selectedTable(in: deck.presentation)?[option] ?? false
            }, set: { [unowned self] isOn in edit { state.setTableOption(option, isOn, in: &$0) } }))
        }
        guard let position = state.selectedCell, table.cell(at: position) != nil else {
            form.note(String(localized: "Mac.Inspector.Table.PickCell"))
            return
        }
        let changes: [(String.LocalizationValue, EditorState.TableChange)] = [
            ("Table.RowAbove", .rowAbove), ("Table.RowBelow", .rowBelow), ("Table.ColumnLeft", .columnLeft),
            ("Table.ColumnRight", .columnRight), ("Table.DeleteRow", .deleteRow), ("Table.DeleteColumn", .deleteColumn),
        ]
        let rows = NSPopUpButton(frame: .zero, pullsDown: true)
        rows.addItem(withTitle: String(localized: "Mac.Inspector.Table.RowsAndColumns"))
        for (key, change) in changes {
            if change == .deleteRow { rows.menu?.addItem(.separator()) }
            let item = NSMenuItem(title: String(localized: key), action: #selector(ActionTarget.run(_:)), keyEquivalent: "")
            let target = ActionTarget { [unowned self] in edit { state.changeTable(change, in: &$0) } }
            item.target = target
            item.representedObject = target
            rows.menu?.addItem(item)
        }
        form.row(nil, rows)
        form.row(String(localized: "Format.Section.CellFill"), form.color(
            choices: colorChoices, noneTitle: String(localized: "Fill.None"), resolve: { [unowned self] in resolve($0) },
            get: { [unowned self] in
                guard let position = state.selectedCell, let cell = state.selectedTable(in: deck.presentation)?.cell(at: position) else {
                    return (nil, false)
                }
                if case .solid(let color) = cell.fill { return (color, false) }
                return (nil, cell.fill == Fill.none)
            },
            set: { [unowned self] color in edit { state.setCellFill(color.map(Fill.solid) ?? Fill.none, in: &$0) } }
        ))
    }

    private var chart: Chart? { state.selectedChart(in: deck.presentation) }

    private func changeChart(_ change: @escaping (inout Chart) -> Void) {
        edit { state.updateChart(in: &$0, change) }
    }

    private func buildChart(_ chart: Chart) {
        form.section(String(localized: "Panel.Chart.Title"))
        let kinds = chart.kind.choices
        let type = form.popup(kinds.map(\.label), get: { [unowned self] in
            self.chart.flatMap { kinds.firstIndex(of: $0.kind) }
        }, set: { [unowned self] index in
            edit { state.setChartKind(kinds[index], in: &$0) }
        })
        for (index, kind) in kinds.enumerated() {
            type.item(at: index)?.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
        }
        form.row(String(localized: "Chart.Type"), type)
        if chart.kind.hasGrouping {
            let groupings = Chart.Grouping.allCases
            let first: String.LocalizationValue = chart.kind == .line || chart.kind == .area
                ? "Chart.Grouping.Standard" : "Chart.Grouping.Clustered"
            form.row(String(localized: "Chart.Grouping"), form.popup(
                [String(localized: first), String(localized: "Chart.Grouping.Stacked"), String(localized: "Chart.Grouping.Percent")],
                get: { [unowned self] in groupings.firstIndex(of: self.chart?.plots.first?.grouping ?? .standard) },
                set: { [unowned self] index in
                    changeChart { chart in
                        for plot in chart.plots.indices { chart.plots[plot].grouping = groupings[index] }
                    }
                }
            ))
        }
        form.row(nil, form.button(String(localized: "ActionBar.ChartData"), symbol: "tablecells") { [unowned self] in
            guard let window = view.window else { return }
            let sheet = ChartDataSheet(deck: deck)
            chartSheet = sheet
            sheet.present(over: window)
        })
        form.row(nil, form.checkbox(String(localized: "Chart.ShowTitle"), get: { [unowned self] in
            self.chart?.title != nil
        }, set: { [unowned self] isOn in
            changeChart {
                $0.title = isOn ? ($0.allSeries.count == 1 ? $0.allSeries[0].name : String(localized: "Chart.DefaultTitle")) : nil
            }
        }))
        if chart.title != nil {
            form.row(String(localized: "Chart.Title"), form.text(placeholder: String(localized: "Chart.Title"), get: { [unowned self] in
                self.chart?.title ?? ""
            }, set: { [unowned self] text in changeChart { $0.title = text } }))
        }
        let positions = ["none", "r", "b", "t", "l"]
        form.row(String(localized: "Chart.Legend"), form.popup(
            ["Chart.Legend.None", "Chart.Legend.Right", "Chart.Legend.Bottom", "Chart.Legend.Top", "Chart.Legend.Left"]
                .map { String(localized: String.LocalizationValue($0)) },
            get: { [unowned self] in
                guard let chart = self.chart else { return nil }
                return positions.firstIndex(of: chart.hasLegend ? chart.legendPosition : "none")
            },
            set: { [unowned self] index in
                let position = positions[index]
                changeChart { chart in
                    chart.hasLegend = position != "none"
                    if position != "none" { chart.legendPosition = position }
                }
            }
        ))
        if chart.kind.hasAxes {
            form.row(nil, form.checkbox(String(localized: "Chart.Gridlines"), get: { [unowned self] in
                self.chart?.showsGridlines ?? false
            }, set: { [unowned self] isOn in changeChart { $0.showsGridlines = isOn } }))
        }
        form.row(nil, form.checkbox(String(localized: "Chart.ValueLabels"), get: { [unowned self] in
            self.chart?.showsValueLabels ?? false
        }, set: { [unowned self] isOn in changeChart { $0.showsValueLabels = isOn } }))
    }

    private func buildPicture() {
        form.section(String(localized: "Format.Section.Picture"))
        let replace = form.button(String(localized: "Picture.Replace"), symbol: "photo.badge.arrow.down") { [unowned self] in
            MediaImporter.chooseReplacement(into: deck, for: view.window)
        }
        let crop = form.button(String(localized: "Picture.Crop"), symbol: "crop") { [unowned self] in
            guard let id = state.selectedShapeID else { return }
            state.croppingShapeID = state.croppingShapeID == id ? nil : id
        }
        let reset = form.button(String(localized: "Picture.ResetCrop"), symbol: "arrow.counterclockwise") { [unowned self] in
            edit { state.resetCrop(in: &$0) }
        }
        let buttons = NSStackView(views: [crop, reset])
        buttons.distribution = .fillEqually
        buttons.spacing = 6
        form.row(nil, replace)
        form.row(nil, buttons)
    }

    /// How a video or sound plays in the slideshow.
    private func buildPlayback(kind: SlideShape.Media.Kind) {
        form.section(String(localized: "Format.Section.Playback"))
        let seconds = String(format: String(localized: "Media.Seconds"), "").trimmingCharacters(in: .whitespaces)
        var media: SlideShape.Media? {
            guard case .picture(let picture)? = deck.selectedShape?.kind else { return nil }
            return picture.media
        }
        func change(_ apply: @escaping (inout SlideShape.Media) -> Void) {
            edit { state.setMedia(in: &$0, apply) }
        }
        let times: [(String.LocalizationValue, KeyPath<SlideShape.Media, Double>, WritableKeyPath<SlideShape.Media, Double>)] = [
            ("Media.TrimStart", \.trimStart, \.trimStart), ("Media.TrimEnd", \.trimEnd, \.trimEnd),
            ("Media.FadeIn", \.fadeIn, \.fadeIn), ("Media.FadeOut", \.fadeOut, \.fadeOut),
        ]
        for (title, read, write) in times {
            form.row(String(localized: title), form.number(
                get: { media?[keyPath: read] ?? 0 },
                set: { value in change { $0[keyPath: write] = value } },
                range: 0...3_600, step: 0.5, unit: seconds
            ))
        }
        form.row(String(localized: "Media.Volume"), form.number(
            get: { ((media?.volume ?? 1) * 100).rounded() },
            set: { value in change { $0.volume = value / 100 } },
            range: 0...100, step: 10, unit: "%"
        ))
        var toggles: [(String.LocalizationValue, WritableKeyPath<SlideShape.Media, Bool>)] = [
            ("Media.Mute", \.isMuted), ("Media.Loop", \.loops), ("Media.Rewind", \.rewinds),
        ]
        if kind == .video {
            toggles += [("Media.FullScreen", \.playsFullScreen)]
        } else {
            toggles += [("Media.AcrossSlides", \.playsAcrossSlides)]
        }
        toggles += [("Media.HideWhenStopped", \.hidesWhenNotPlaying)]
        for (title, path) in toggles {
            form.row(nil, form.checkbox(String(localized: title), get: { media?[keyPath: path] ?? false }, set: { isOn in
                change { $0[keyPath: path] = isOn }
            }))
        }
        form.note(String(localized: "Format.Playback.Footer"))
    }

    // MARK: - Arranging

    private func buildArrange(_ shape: SlideShape) {
        form.section(String(localized: "Format.Section.Arrange"))
        if !state.hasMultipleSelection {
            func frameField(_ get: @escaping (CGRect) -> CGFloat, _ set: @escaping (inout CGRect, CGFloat) -> Void,
                            minimum: Double) -> NSView {
                form.number(get: { [unowned self] in
                    Double(get(deck.selectedShape?.frame.points ?? .zero))
                }, set: { [unowned self] value in
                    guard let shape = deck.selectedShape else { return }
                    var frame = shape.frame.points
                    set(&frame, CGFloat(value))
                    edit { state.setTransform(frame: frame, rotation: shape.rotation, of: shape.id, in: &$0) }
                }, range: minimum...10_000, step: 1)
            }
            form.pair(String(localized: "Mac.Inspector.Position"),
                      ("X", frameField({ $0.minX }, { $0.origin.x = $1 }, minimum: -10_000)),
                      ("Y", frameField({ $0.minY }, { $0.origin.y = $1 }, minimum: -10_000)))
            form.pair(String(localized: "Mac.Inspector.Size"),
                      (String(localized: "Mac.Inspector.Width.Short"), frameField({ $0.width }, { $0.size.width = $1 }, minimum: 0)),
                      (String(localized: "Mac.Inspector.Height.Short"), frameField({ $0.height }, { $0.size.height = $1 }, minimum: 0)))
            if shape.canRotate {
                form.row(String(localized: "Format.Rotation"), form.number(get: { [unowned self] in
                    (deck.selectedShape?.rotation ?? 0).rounded()
                }, set: { [unowned self] value in
                    guard let shape = deck.selectedShape else { return }
                    edit { state.setTransform(frame: shape.frame.points, rotation: value, of: shape.id, in: &$0) }
                }, range: -360...720, step: 1, unit: "°"))
                form.row(nil, form.actions([
                    ("rotate.left", String(localized: "Arrange.RotateLeft")), ("rotate.right", String(localized: "Arrange.RotateRight")),
                    ("arrow.left.and.right.righttriangle.left.righttriangle.right", String(localized: "Arrange.FlipHorizontal")),
                    ("arrow.up.and.down.righttriangle.up.righttriangle.down", String(localized: "Arrange.FlipVertical")),
                ]) { [unowned self] index in
                    switch index {
                    case 0: edit { state.rotateSelectedShape(clockwise: false, in: &$0) }
                    case 1: edit { state.rotateSelectedShape(clockwise: true, in: &$0) }
                    case 2: edit { state.flipSelectedShape(horizontally: true, in: &$0) }
                    default: edit { state.flipSelectedShape(horizontally: false, in: &$0) }
                    }
                })
            }
        }
        let alignments: [EditorState.Alignment] = [.left, .center, .right, .top, .middle, .bottom]
        form.row(String(localized: "ActionBar.Align"), form.actions([
            ("align.horizontal.left", String(localized: "Align.Left")), ("align.horizontal.center", String(localized: "Align.Center")),
            ("align.horizontal.right", String(localized: "Align.Right")), ("align.vertical.top", String(localized: "Align.Top")),
            ("align.vertical.center", String(localized: "Align.Middle")), ("align.vertical.bottom", String(localized: "Align.Bottom")),
        ]) { [unowned self] index in
            edit { state.alignSelectedShapes(alignments[index], in: &$0) }
        })
        form.row(nil, form.actions([
            ("square.3.layers.3d.top.filled", String(localized: "Arrange.Front")),
            ("square.2.layers.3d.top.filled", String(localized: "Arrange.Forward")),
            ("square.2.layers.3d.bottom.filled", String(localized: "Arrange.Backward")),
            ("square.3.layers.3d.bottom.filled", String(localized: "Arrange.Back")),
        ]) { [unowned self] index in
            let arrangements: [EditorState.Arrangement] = [.front, .forward, .backward, .back]
            edit { state.arrangeSelectedShape(arrangements[index], in: &$0) }
        })
    }

    private func buildDescription() {
        form.section(String(localized: "Format.Section.AltText"))
        form.add(form.text(placeholder: String(localized: "Format.AltText.Placeholder"), get: { [unowned self] in
            deck.selectedShape?.altText ?? ""
        }, set: { [unowned self] text in
            edit { state.setAltText(text, in: &$0) }
        }), fill: true)
        form.note(String(localized: "Format.AltText.Footer"))
    }

    // MARK: - The slide

    private func buildSlide(_ slide: Slide) {
        form.section(String(localized: "Format.Section.Background"))
        form.row(String(localized: "Fill.Kind"), form.color(
            choices: colorChoices, noneTitle: String(localized: "Fill.Automatic"), noneIsAutomatic: true,
            resolve: { [unowned self] in resolve($0) },
            get: { [unowned self] in
                switch deck.selectedSlide?.background {
                case nil: return (nil, true)
                case .fill(.solid(let color))?: return (color, false)
                default: return (nil, false)
                }
            },
            set: { [unowned self] color in edit { state.setBackground(color.map(Fill.solid), in: &$0) } }
        ))
        form.note(String(localized: "Format.Background.Footer"))

        // A master or layout has a name, and none of what a slide has besides.
        if deck.presentation.isInMasterView {
            guard slide.role != .master else { return }
            form.section(String(localized: "MasterView.Section.Layout"))
            form.row(String(localized: "MasterView.LayoutName"), form.text(placeholder: "", get: { [unowned self] in
                deck.selectedSlide?.layoutName ?? ""
            }, set: { [unowned self] name in
                guard let id = deck.selectedSlide?.id else { return }
                edit { state.renameLayout(id, to: name, in: &$0) }
            }))
            return
        }

        form.section(String(localized: "Format.Section.Slide"))
        form.row(String(localized: "Format.Slide.Layout"), NSTextField(labelWithString: deck.presentation.layout(for: slide)?.name ?? ""))
        form.row(nil, form.checkbox(String(localized: "Format.Slide.Hidden"), get: { [unowned self] in
            deck.selectedSlide?.isHidden ?? false
        }, set: { [unowned self] _ in
            guard let id = deck.selectedSlide?.id else { return }
            edit { state.toggleHidden(id, in: &$0) }
        }))

        form.section(String(localized: "Format.Section.Advance"))
        form.row(nil, form.checkbox(String(localized: "Advance.Automatically"), get: { [unowned self] in
            deck.selectedSlide?.autoAdvanceAfter != nil
        }, set: { [unowned self] isOn in edit { state.setAutoAdvance(isOn ? 5 : nil, in: &$0) } }))
        if slide.autoAdvanceAfter != nil {
            form.row(String(localized: "Advance.After"), form.number(get: { [unowned self] in
                deck.selectedSlide?.autoAdvanceAfter ?? 5
            }, set: { [unowned self] seconds in
                edit { state.setAutoAdvance(max(seconds, 0.5), in: &$0) }
            }, range: 0.5...3_600, step: 0.5, unit: String(localized: "Advance.Seconds")))
            form.row(nil, form.checkbox(String(localized: "Advance.OnTap"), get: { [unowned self] in
                deck.selectedSlide?.advancesOnClick ?? true
            }, set: { [unowned self] isOn in edit { state.setAdvancesOnClick(isOn, in: &$0) } }))
        }
        form.row(nil, form.button(String(localized: "Advance.ApplyToAll")) { [unowned self] in
            guard let slide = deck.selectedSlide else { return }
            edit {
                state.setAutoAdvance(slide.autoAdvanceAfter, toAll: true, in: &$0)
                state.setAdvancesOnClick(slide.advancesOnClick, toAll: true, in: &$0)
            }
        })
        form.note(String(localized: "Advance.Footer"))

        form.section(String(localized: "Format.Section.Presentation"))
        let presets = SlideSizeConverter.Preset.allCases
        let shown = { [unowned self] in Self.preset(shaped: deck.presentation.slideSize) }
        let isCustom = shown() == nil
        form.row(String(localized: "Format.SlideSize"), form.popup(
            presets.map(\.label) + (isCustom ? [String(localized: "SlideSize.Custom")] : []),
            get: { shown().flatMap(presets.firstIndex(of:)) ?? presets.count },
            set: { [unowned self] index in
                // Picking the shape the slides already have changes nothing.
                guard presets.indices.contains(index), presets[index] != shown() else { return }
                askToResize(to: presets[index])
            }
        ))
        buildSlideshowSettings()
    }

    /// How every slideshow of the presentation plays: PowerPoint's Set Up Slide Show.
    private func buildSlideshowSettings() {
        form.section(String(localized: "Show.Title"))
        let settings = { [unowned self] in deck.presentation.showSettings }
        let update = { [unowned self] (change: @escaping (inout SlideshowSettings) -> Void) in
            edit { state.updateShowSettings(in: &$0, change) }
        }
        let hasShows = !deck.presentation.customShows.isEmpty
        var ranges = [String(localized: "Show.Range.All"), String(localized: "Show.Range.Slides")]
        if hasShows || { if case .customShow = settings().range { true } else { false } }() {
            ranges.append(String(localized: "Show.Range.CustomShow"))
        }
        form.row(String(localized: "Show.Range"), form.popup(ranges, get: {
            switch settings().range {
            case .all: 0
            case .slides: 1
            case .customShow: 2
            }
        }, set: { [unowned self] index in
            let count = max(deck.presentation.slides.count, 1)
            let first = deck.presentation.customShows.first?.id
            update { settings in
                switch index {
                case 1: settings.range = .slides(from: 1, to: count)
                case 2: settings.range = first.map(SlideshowSettings.Range.customShow) ?? .all
                default: settings.range = .all
                }
            }
        }))
        let maximum = Double(max(deck.presentation.slides.count, 1))
        let from = form.number(get: {
            if case .slides(let from, _) = settings().range { return Double(from) }
            return 1
        }, set: { value in
            update { settings in
                guard case .slides(_, let to) = settings.range else { return }
                settings.range = .slides(from: Int(value), to: max(Int(value), to))
            }
        }, range: 1...maximum, step: 1)
        let to = form.number(get: {
            if case .slides(_, let to) = settings().range { return Double(to) }
            return maximum
        }, set: { value in
            update { settings in
                guard case .slides(let from, _) = settings.range else { return }
                settings.range = .slides(from: min(from, Int(value)), to: Int(value))
            }
        }, range: 1...maximum, step: 1)
        form.pair(nil, (String(localized: "Show.From"), from), (String(localized: "Show.To"), to))
        let shows = deck.presentation.customShows
        let showPopup = form.popup(shows.map(\.name), get: {
            if case .customShow(let id) = settings().range { return shows.firstIndex { $0.id == id } }
            return nil
        }, set: { index in
            guard shows.indices.contains(index) else { return }
            update { $0.range = .customShow(shows[index].id) }
        })
        form.row(nil, showPopup)
        form.row(nil, form.checkbox(String(localized: "Show.Kiosk"), get: { settings().isKiosk }, set: { isOn in
            update { $0.isKiosk = isOn }
        }))
        let restart = form.number(get: { settings().kioskRestartAfter / 60 }, set: { minutes in
            update { $0.kioskRestartAfter = max(minutes, 1) * 60 }
        }, range: 1...60, step: 1, unit: String(localized: "Show.Minutes"))
        form.row(String(localized: "Show.KioskRestart"), restart)
        let loop = form.checkbox(String(localized: "Format.LoopSlideshow"), get: { settings().loops || settings().isKiosk }, set: { [unowned self] isOn in
            edit { state.setLoopsSlideshow(isOn, in: &$0) }
        })
        form.row(nil, loop)
        let timings = form.checkbox(String(localized: "Show.UseTimings"), get: { settings().usesTimings || settings().isKiosk }, set: { isOn in
            update { $0.usesTimings = isOn }
        })
        form.row(nil, timings)
        form.row(nil, form.checkbox(String(localized: "Show.ShowAnimations"), get: { settings().showsAnimations }, set: { isOn in
            update { $0.showsAnimations = isOn }
        }))
        form.row(nil, form.checkbox(String(localized: "Show.PlayNarration"), get: { settings().playsNarration }, set: { isOn in
            update { $0.playsNarration = isOn }
        }))
        // What the settings do: a kiosk show's explanation while it is one.
        let note = NSTextField(wrappingLabelWithString: String(localized: "Show.Footer"))
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        form.add(note, fill: true)
        form.onUpdate {
            let current = settings()
            var isSlides = false
            if case .slides = current.range { isSlides = true }
            var isShow = false
            if case .customShow = current.range { isShow = true }
            from.superview?.isHidden = !isSlides
            showPopup.isHidden = !isShow
            restart.superview?.isHidden = !current.isKiosk
            loop.isEnabled = !current.isKiosk
            timings.isEnabled = !current.isKiosk
            note.stringValue = String(localized: current.isKiosk ? "Show.Kiosk.Footer" : "Show.Footer")
        }
        form.row(nil, form.button(String(localized: "Menu.Play.CustomShows")) { [unowned self] in
            (view.window?.windowController as? DocumentWindowController)?.showCustomShows(nil)
        })
    }

    /// The preset a slide size is, or has the shape of: a 16:9 deck made 10
    /// inches wide is widescreen, as PowerPoint's own is 13.33 inches.
    static func preset(shaped size: EMUSize) -> SlideSizeConverter.Preset? {
        SlideSizeConverter.Preset.matching(size) ?? SlideSizeConverter.Preset.allCases.first {
            abs($0.size.aspectRatio - size.aspectRatio) < 0.005
        }
    }

    /// Asks how to fit what is on the slides to a new size, then resizes.
    private func askToResize(to preset: SlideSizeConverter.Preset) {
        let alert = NSAlert()
        alert.messageText = String(localized: "SlideSize.Scaling.Title")
        alert.informativeText = String(localized: "SlideSize.Scaling.Message")
        alert.addButton(withTitle: String(localized: "SlideSize.Scaling.Maximize"))
        alert.addButton(withTitle: String(localized: "SlideSize.Scaling.EnsureFit"))
        alert.addButton(withTitle: String(localized: "Common.Cancel"))
        let resize = { [unowned self] (response: NSApplication.ModalResponse) in
            let scaling: SlideSizeConverter.Scaling
            switch response {
            case .alertFirstButtonReturn: scaling = .maximize
            case .alertSecondButtonReturn: scaling = .ensureFit
            default:
                form.update()
                return
            }
            edit { state.setSlideSize(preset, scaling: scaling, in: &$0) }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: resize)
        } else {
            resize(alert.runModal())
        }
    }
}
