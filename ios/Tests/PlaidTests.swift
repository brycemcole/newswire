import Foundation
import Testing
@testable import Newswire

struct PlaidTests {
    @Test func parsesOptionHoldings() throws {
        let json = """
        {"accounts":[{"account_id":"a1","name":"Brokerage","mask":"1234"}],
         "holdings":[
          {"account_id":"a1","security_id":"opt1","quantity":2,"institution_price":3.5,"institution_value":700,"cost_basis":500},
          {"account_id":"a1","security_id":"opt2","quantity":-300,"institution_price":1.2,"institution_value":-360,"cost_basis":null},
          {"account_id":"a1","security_id":"stk","quantity":10,"institution_price":100,"institution_value":1000,"cost_basis":900},
          {"account_id":"a1","security_id":"cash","quantity":50,"institution_price":1,"institution_value":50,"cost_basis":50}],
         "securities":[
          {"security_id":"opt1","ticker_symbol":"NVDA261016C00150000","type":"derivative","option_contract":{"contract_type":"call","expiration_date":"2026-10-16","strike_price":150,"underlying_security_ticker":"nvda"}},
          {"security_id":"opt2","ticker_symbol":null,"type":"derivative","option_contract":{"contract_type":"put","expiration_date":"2026-11-20","strike_price":90.5,"underlying_security_ticker":"AAPL"}},
          {"security_id":"stk","ticker_symbol":"MSFT","type":"equity","option_contract":null},
          {"security_id":"cash","ticker_symbol":"USD","type":"cash","option_contract":null}]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(HoldingsResponse.self, from: Data(json.utf8))
        let item = PlaidItem(id: "item", accessToken: "token", institution: "Fidelity", environment: .sandbox)
        let parsed = response.positions(item: item)
        #expect(parsed.cash == 50)
        #expect(parsed.positions.count == 3)
        let stock = try #require(parsed.positions.first { $0.option == nil })
        #expect(stock.symbol == "MSFT" && stock.gain == 100)
        let call = try #require(parsed.positions.first { $0.option?.isCall == true })
        #expect(call.symbol == "NVDA" && call.option?.strike == 150 && call.option?.contracts == 2)
        #expect(call.gain == 200 && call.account == "Brokerage ••1234")
        #expect(call.breakeven == 152.5)
        #expect(call.option?.intrinsic(at: 160) == 2000)
        let put = try #require(parsed.positions.first { $0.option?.isCall == false })
        #expect(put.option?.contracts == -3 && put.option?.strike == 90.5)
        let expiration = try #require(put.option?.expiration)
        #expect(Calendar.current.dateComponents([.year, .month, .day], from: expiration) == DateComponents(year: 2026, month: 11, day: 20))
    }

    @Test func estimatesCostFromTrades() throws {
        let json = """
        [{"account_id":"a","security_id":"s","type":"sell","quantity":-1,"amount":-300,"date":"2026-03-01"},
         {"account_id":"a","security_id":"s","type":"buy","quantity":1,"amount":250,"date":"2026-02-01"},
         {"account_id":"a","security_id":"s","type":"buy","quantity":1,"amount":150,"date":"2026-01-01"},
         {"account_id":"a","security_id":"s","type":"cash","quantity":0,"amount":5,"date":"2026-01-01"}]
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let trades = try decoder.decode([PlaidClient.Transactions.Transaction].self, from: Data(json.utf8))
        #expect(HoldingsResponse.estimatedCost(quantity: 1, trades: trades) == 250)
        #expect(HoldingsResponse.estimatedCost(quantity: 2, trades: trades) == nil)
        #expect(HoldingsResponse.estimatedCost(quantity: -1, trades: trades) == -300)
        #expect(HoldingsResponse.estimatedCost(quantity: 1, trades: []) == nil)
    }

    @Test func pricesOptions() throws {
        let put = BlackScholes.price(call: false, spot: 100, strike: 100, years: 1, volatility: 0.2, rate: 0.05)
        #expect(abs(put - 5.573) < 0.01)
        let call = BlackScholes.price(call: true, spot: 100, strike: 100, years: 1, volatility: 0.2, rate: 0.05)
        #expect(abs(call - 10.451) < 0.01)
        let volatility = try #require(BlackScholes.impliedVolatility(call: false, premium: 1.95, spot: 1777.8, strike: 1470, years: 4.0 / 365))
        let back = BlackScholes.price(call: false, spot: 1777.8, strike: 1470, years: 4.0 / 365, volatility: volatility)
        #expect(abs(back - 1.95) < 0.001)
        #expect(BlackScholes.price(call: false, spot: 1725.63, strike: 1470, years: 4.0 / 365, volatility: volatility) > 1.95)
    }
}
