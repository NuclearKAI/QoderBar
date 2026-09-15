import Testing
@testable import QoderBar

@Suite struct FormatTests {
    @Test func compact() {
        #expect(Fmt.compact(999) == "999")
        #expect(Fmt.compact(1500) == "1.50K")
        #expect(Fmt.compact(12_345) == "12.3K")
        #expect(Fmt.compact(2_500_000) == "2.50M")
    }

    @Test func countdown() {
        #expect(Fmt.countdown(59) == "59秒")
        #expect(Fmt.countdown(90) == "1分钟")
        #expect(Fmt.countdown(3661) == "1小时1分")
        #expect(Fmt.countdown(90_061) == "1天1小时")
        #expect(Fmt.countdown(-5) == "0秒")
    }

    @Test func duration() {
        #expect(Fmt.duration(9.6) == "10秒")
        #expect(Fmt.duration(90) == "1分30秒")
        #expect(Fmt.duration(3700) == "1小时1分")
    }

    @Test func tps() {
        #expect(Fmt.tps(0) == "0")
        #expect(Fmt.tps(9.876) == "9.88")
        #expect(Fmt.tps(42.5) == "42.5")
        #expect(Fmt.tps(150.4) == "150")
    }
}
