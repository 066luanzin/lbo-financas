import Foundation
import SwiftData

extension Financas {
    @MainActor
    static func carregar(_ ctx: ModelContext) -> Financas {
        Financas(transacoes: (try? ctx.fetch(FetchDescriptor<Transacao>())) ?? [],
                 contas: (try? ctx.fetch(FetchDescriptor<Conta>())) ?? [],
                 carteiras: (try? ctx.fetch(FetchDescriptor<Carteira>(sortBy: [SortDescriptor(\.ordem)]))) ?? [])
    }
}

@MainActor
enum Ajuste {
    /// Deixa cada banco igual ao app dele e o total igual à soma dos bancos
    static func igualarBancos(_ reais: [String: Double], ctx: ModelContext) {
        let mes = Mes.indice()
        var fin = Financas.carregar(ctx)
        for (nome, real) in reais {
            igualar(real: real, atual: fin.saldoCarteira(nome, ate: mes), carteira: nome, mes: mes, fin: fin, ctx: ctx)
        }
        fin = Financas.carregar(ctx)
        let bancos = Set(fin.bancos().map(\.nome))
        let soma = fin.bancos().reduce(0) { $0 + (reais[$1.nome] ?? fin.saldoCarteira($1.nome, ate: mes)) }
        // o que não tem banco (ajustes antigos, faturas, adiantamentos) fica zerado: total = soma dos bancos
        igualar(real: soma, atual: fin.saldo(em: mes), carteira: "", mes: mes, fin: fin, ctx: ctx)
    }

    /// Deixa o saldo (geral ou de uma conta) igual ao valor real do banco.
    /// Troca os ajustes antigos do mês (daquela conta) por um só, com a diferença certa.
    static func igualar(real: Double, atual: Double, carteira: String, mes: Int, fin: Financas, ctx: ModelContext) {
        let semAjuste = atual - fin.ajustes(em: mes, carteira: carteira)
        for t in fin.transacoes(em: mes) where t.ehAjuste && t.carteira == carteira { ctx.delete(t) }
        let diferenca = real - semAjuste
        if abs(diferenca) >= 0.01 {
            ctx.insert(Transacao(tipo: diferenca > 0 ? .receita : .gasto, valor: abs(diferenca),
                                 categoria: Transacao.categoriaAjuste, carteira: carteira,
                                 descricao: carteira.isEmpty ? "Ajuste de saldo" : "Ajuste de saldo · \(carteira)"))
        }
        try? ctx.save()
    }
}
