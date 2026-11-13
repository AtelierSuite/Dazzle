import Foundation

extension Chart {
    /// A line fitted to a series' points, `c:trendline`.
    public struct Trendline: Equatable, Hashable, Sendable {
        public enum Kind: String, CaseIterable, Sendable {
            case linear
            /// y = c·e^(bx), for positive values.
            case exp
            /// y = b·ln(x) + a, for positive x.
            case log
            /// y = a + bx + cx² …, up to the sixth power.
            case poly
            /// y = c·x^b, for positive x and values.
            case power
            /// The average of each point and the `period - 1` before it.
            case movingAvg
        }

        public var kind: Kind
        /// The highest power of a polynomial, 2 to 6.
        public var order = 2
        /// How many points a moving average takes in, 2 or more.
        public var period = 2
        /// How far past the last point and before the first the line runs, in x.
        public var forward = 0.0
        public var backward = 0.0
        /// Where a linear, exponential or polynomial line crosses x = 0, if fixed.
        public var intercept: Double?
        /// The name the legend gives the line, where the file names it.
        public var name: String?
        public var showsEquation = false
        public var showsRSquared = false
        /// Its outline, `c:spPr/a:ln`.
        public var line: LineStyle?

        public init(kind: Kind, order: Int = 2, period: Int = 2) {
            self.kind = kind
            self.order = order
            self.period = period
        }

        init(element: XMLElement) {
            func value(_ name: String) -> String? { element.firstChild(named: name)?.attribute("val") }
            kind = value("trendlineType").flatMap(Kind.init(rawValue:)) ?? .linear
            order = min(max(value("order").flatMap(Int.init) ?? 2, 2), 6)
            period = max(value("period").flatMap(Int.init) ?? 2, 2)
            forward = value("forward").flatMap(Double.init) ?? 0
            backward = value("backward").flatMap(Double.init) ?? 0
            intercept = value("intercept").flatMap(Double.init)
            name = element.firstChild(named: "name")?.text.nilIfEmpty
            showsEquation = value("dispEq").map { $0 == "1" || $0 == "true" } ?? false
            showsRSquared = value("dispRSqr").map { $0 == "1" || $0 == "true" } ?? false
            line = element.firstChild(named: "spPr")?.firstChild(named: "ln").map(LineStyle.init(element:))
        }

        /// A line fitted to points: what it gives at any x, and how well it fits.
        public struct Fit: Sendable {
            public var kind: Kind
            /// For a polynomial or linear line, a + bx + cx² …; for an
            /// exponential, logarithmic or power line, the two numbers of its form.
            public var coefficients: [Double]
            public var rSquared: Double

            public func value(at x: Double) -> Double? {
                let result: Double
                switch kind {
                case .linear, .poly, .movingAvg:
                    result = coefficients.reversed().reduce(0) { $0 * x + $1 }
                case .exp:
                    result = coefficients[0] * Foundation.exp(coefficients[1] * x)
                case .log:
                    guard x > 0 else { return nil }
                    result = coefficients[0] + coefficients[1] * Foundation.log(x)
                case .power:
                    guard x > 0 else { return nil }
                    result = coefficients[0] * pow(x, coefficients[1])
                }
                return result.isFinite ? result : nil
            }

            /// The equation as PowerPoint labels it, such as `y = 0.5x + 2`.
            public var equation: String {
                let a = coefficients[0]
                let b = coefficients.count > 1 ? coefficients[1] : 0
                switch kind {
                case .exp: return "y = \(Fit.number(a))e^\(Fit.number(b))x"
                case .log: return "y = \(Fit.number(b))ln(x)" + Fit.signed(a)
                case .power: return "y = \(Fit.number(a))x^\(Fit.number(b))"
                case .linear, .poly, .movingAvg:
                    let powers = ["", "x", "x²", "x³", "x⁴", "x⁵", "x⁶"]
                    var text = ""
                    for (power, coefficient) in coefficients.enumerated().reversed() where coefficient != 0 || (power == 0 && text.isEmpty) {
                        let size = Fit.number(abs(coefficient))
                        let term = (size == "1" && power > 0 ? "" : size) + powers[min(power, 6)]
                        text += text.isEmpty ? (coefficient < 0 ? "-" : "") + term : (coefficient < 0 ? " - " : " + ") + term
                    }
                    return "y = " + text
                }
            }

            /// R², as PowerPoint labels it.
            public var rSquaredText: String { "R² = \(Fit.number(rSquared))" }

            static func number(_ value: Double) -> String {
                let text = String(format: "%.4g", value)
                return text == "-0" ? "0" : text
            }

            static func signed(_ value: Double) -> String {
                value == 0 ? "" : (value < 0 ? " - " : " + ") + number(abs(value))
            }
        }

        /// The line fitted to `points`, x and y, or `nil` if there are too few
        /// that its kind can take: an exponential line needs positive values,
        /// a logarithmic line positive x, and a power line both.
        public func fit(_ points: [(x: Double, y: Double)]) -> Fit? {
            switch kind {
            case .linear, .poly:
                let degree = kind == .linear ? 1 : order
                guard let coefficients = Self.polynomial(points, degree: degree, intercept: intercept) else { return nil }
                let fit = Fit(kind: kind, coefficients: coefficients, rSquared: 0)
                return Self.withRSquared(fit, points.map { ($0.y, fit.value(at: $0.x) ?? 0) }, fixed: intercept != nil)
            case .exp:
                let usable = points.filter { $0.y > 0 }.map { (x: $0.x, y: Foundation.log($0.y)) }
                let fixed = intercept.flatMap { $0 > 0 ? Foundation.log($0) : nil }
                guard let line = Self.polynomial(usable, degree: 1, intercept: fixed) else { return nil }
                return Self.withRSquared(Fit(kind: .exp, coefficients: [Foundation.exp(line[0]), line[1]], rSquared: 0),
                                         usable.map { ($0.y, line[0] + line[1] * $0.x) }, fixed: fixed != nil)
            case .log:
                let usable = points.filter { $0.x > 0 }.map { (x: Foundation.log($0.x), y: $0.y) }
                guard let line = Self.polynomial(usable, degree: 1, intercept: nil) else { return nil }
                return Self.withRSquared(Fit(kind: .log, coefficients: line, rSquared: 0),
                                         usable.map { ($0.y, line[0] + line[1] * $0.x) }, fixed: false)
            case .power:
                let usable = points.filter { $0.x > 0 && $0.y > 0 }.map { (x: Foundation.log($0.x), y: Foundation.log($0.y)) }
                guard let line = Self.polynomial(usable, degree: 1, intercept: nil) else { return nil }
                return Self.withRSquared(Fit(kind: .power, coefficients: [Foundation.exp(line[0]), line[1]], rSquared: 0),
                                         usable.map { ($0.y, line[0] + line[1] * $0.x) }, fixed: false)
            case .movingAvg:
                return nil
            }
        }

        /// A moving average's points: each the mean of its own value and the
        /// `period - 1` before it, at its own x.
        public func movingAverage(_ points: [(x: Double, y: Double)]) -> [(x: Double, y: Double)] {
            guard period >= 2, points.count >= period else { return [] }
            return (period - 1..<points.count).map { index in
                let window = points[(index - period + 1)...index]
                return (points[index].x, window.map(\.y).reduce(0, +) / Double(period))
            }
        }

        /// The least-squares polynomial a + bx + cx² … of `degree` through
        /// `points`, its constant fixed at `intercept` if one is given.
        static func polynomial(_ points: [(x: Double, y: Double)], degree: Int, intercept: Double?) -> [Double]? {
            let first = intercept == nil ? 0 : 1
            let unknowns = degree + 1 - first
            guard unknowns > 0, points.count >= unknowns + (intercept == nil ? 1 : 0) else { return nil }
            // Normal equations: Σ x^(i+j) · c_j = Σ x^i · (y - intercept).
            var matrix = [[Double]](repeating: [Double](repeating: 0, count: unknowns + 1), count: unknowns)
            for point in points {
                let target = point.y - (intercept ?? 0)
                for row in 0..<unknowns {
                    let xRow = pow(point.x, Double(row + first))
                    for column in 0..<unknowns { matrix[row][column] += xRow * pow(point.x, Double(column + first)) }
                    matrix[row][unknowns] += xRow * target
                }
            }
            // Gaussian elimination, largest pivot first.
            for column in 0..<unknowns {
                guard let pivot = (column..<unknowns).max(by: { abs(matrix[$0][column]) < abs(matrix[$1][column]) }),
                      abs(matrix[pivot][column]) > 1e-12 else { return nil }
                matrix.swapAt(column, pivot)
                for row in 0..<unknowns where row != column {
                    let factor = matrix[row][column] / matrix[column][column]
                    for entry in column...unknowns { matrix[row][entry] -= factor * matrix[column][entry] }
                }
            }
            let solved = (0..<unknowns).map { matrix[$0][unknowns] / matrix[$0][$0] }
            guard solved.allSatisfy(\.isFinite) else { return nil }
            return (intercept.map { [$0] } ?? []) + solved
        }

        /// R² of a fit from its actual and fitted values; measured from zero
        /// rather than the mean where the intercept is fixed, as Excel does.
        private static func withRSquared(_ fit: Fit, _ pairs: [(actual: Double, fitted: Double)], fixed: Bool) -> Fit {
            var fit = fit
            let mean = fixed ? 0 : pairs.map(\.actual).reduce(0, +) / Double(max(pairs.count, 1))
            let residual = pairs.map { pow($0.actual - $0.fitted, 2) }.reduce(0, +)
            let total = pairs.map { pow($0.actual - mean, 2) }.reduce(0, +)
            fit.rSquared = total > 0 ? 1 - residual / total : 1
            return fit
        }
    }

    /// Error bars on a series' points, `c:errBars`.
    public struct ErrorBars: Equatable, Hashable, Sendable {
        /// Which axis the bars run along: values (`y`) or, for an x-y chart, x.
        public enum Direction: String, Sendable {
            case x
            case y
        }

        /// Which way from each point they run.
        public enum BarType: String, CaseIterable, Sendable {
            case both
            case plus
            case minus
        }

        /// How long they are.
        public enum ValueType: String, CaseIterable, Sendable {
            /// `value` either way.
            case fixedVal
            /// `value` percent of the point's own value.
            case percentage
            /// `value` standard deviations of the series, either side of its mean.
            case stdDev
            /// The series' standard error.
            case stdErr
            /// Each point's own amounts, `plus` and `minus`.
            case cust
        }

        public var direction = Direction.y
        public var barType = BarType.both
        public var valueType = ValueType.fixedVal
        public var value = 1.0
        /// Whether the bars end without a crossbar.
        public var hasEndCap = true
        /// A custom amount above and below each point.
        public var plus: [Double?] = []
        public var minus: [Double?] = []
        /// Its outline, `c:spPr/a:ln`.
        public var line: LineStyle?

        public init(direction: Direction = .y, barType: BarType = .both, valueType: ValueType = .fixedVal, value: Double = 1) {
            self.direction = direction
            self.barType = barType
            self.valueType = valueType
            self.value = value
        }

        init(element: XMLElement, numbers: (XMLElement?) -> [Double?]) {
            func value(_ name: String) -> String? { element.firstChild(named: name)?.attribute("val") }
            direction = value("errDir").flatMap(Direction.init(rawValue:)) ?? .y
            barType = value("errBarType").flatMap(BarType.init(rawValue:)) ?? .both
            valueType = value("errValType").flatMap(ValueType.init(rawValue:)) ?? .fixedVal
            self.value = value("val").flatMap(Double.init) ?? 1
            hasEndCap = !(value("noEndCap").map { $0 == "1" || $0 == "true" } ?? false)
            plus = numbers(element.firstChild(named: "plus"))
            minus = numbers(element.firstChild(named: "minus"))
            line = element.firstChild(named: "spPr")?.firstChild(named: "ln").map(LineStyle.init(element:))
        }

        /// Where each point's bar runs from and to, given the series' own
        /// values along the bar's axis; `nil` where the point has no value.
        /// Standard deviation bars stand about the series' mean, as Office
        /// draws them; the rest about the point itself.
        public func extents(of values: [Double?]) -> [(center: Double?, minus: Double, plus: Double)?] {
            let known = values.compactMap(\.self)
            let count = Double(known.count)
            let mean = count > 0 ? known.reduce(0, +) / count : 0
            let deviation = count > 1 ? (known.map { pow($0 - mean, 2) }.reduce(0, +) / (count - 1)).squareRoot() : 0
            let standardError = count > 1 ? (known.map { $0 * $0 }.reduce(0, +) / (count * (count - 1))).squareRoot() : 0
            return values.enumerated().map { index, point in
                guard let point else { return nil }
                var center: Double?
                var below: Double
                var above: Double
                switch valueType {
                case .fixedVal: (below, above) = (abs(value), abs(value))
                case .percentage: (below, above) = (abs(point * value / 100), abs(point * value / 100))
                case .stdDev:
                    center = mean
                    (below, above) = (deviation * abs(value), deviation * abs(value))
                case .stdErr: (below, above) = (standardError, standardError)
                case .cust:
                    above = plus.indices.contains(index) ? plus[index].map(abs) ?? 0 : 0
                    below = minus.indices.contains(index) ? minus[index].map(abs) ?? 0 : 0
                }
                if barType == .plus { below = 0 }
                if barType == .minus { above = 0 }
                return (center, below, above)
            }
        }
    }
}
