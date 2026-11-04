import Foundation
import SwiftData

/// Ajustes de dados que rodam uma vez só depois de uma atualização
@MainActor
enum Migracao {
    /// O saldo agora passa de um mês pro outro. Quem já tinha ajustado o saldo neste mês
    /// (quando cada mês começava do zero) teria o dinheiro contado duas vezes: troca os ajustes
    /// do mês por um só, pra o saldo continuar exatamente o mesmo de antes.
    /// Pix é forma de pagar, não banco: junta no Nubank. Cria Mercado Pago e Banco do Brasil.
    static func bancos(_ ctx: ModelContext) {
        let chave = "migracaoBancos-" + (UserDefaults.standard.string(forKey: "uidAtual") ?? "")
        guard !UserDefaults.standard.bool(forKey: chave) else { return }
        var carts = (try? ctx.fetch(FetchDescriptor<Carteira>(sortBy: [SortDescriptor(\.ordem)]))) ?? []
        guard !carts.isEmpty else { return }
        let norm: (String) -> String = { PlanoCalculo.chave($0) }
        func achar(_ nome: String) -> Carteira? { carts.first { norm($0.nome) == norm(nome) && $0.tipo != .credito } }

        if let pix = carts.first(where: { $0.nome == "Pix" && $0.tipo == .pix }) {
            let alvo = achar("Nubank").map(\.nome) ?? "Nubank"
            for t in (try? ctx.fetch(FetchDescriptor<Transacao>())) ?? [] {
                if t.carteira == "Pix" { t.carteira = alvo }
                if t.destino == "Pix" { t.destino = alvo }
            }
            for r in (try? ctx.fetch(FetchDescriptor<Recorrencia>())) ?? [] where r.carteira == "Pix" { r.carteira = alvo }
            for c in (try? ctx.fetch(FetchDescriptor<Conta>())) ?? [] {
                c.pagamentos = c.pagamentos.map {
                    var e = $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    if e.count > 1 && e[1] == "Pix" { e[1] = alvo }
                    return e.joined(separator: "|")
                }
            }
            if achar("Nubank") != nil {
                ctx.delete(pix)
                carts.removeAll { $0 === pix }
            } else {
                pix.nome = alvo
                pix.tipoRaw = TipoCarteira.debito.rawValue
            }
        }
        var ordem = (carts.map(\.ordem).max() ?? 0) + 1
        for nome in ["Mercado Pago", "Banco do Brasil"] where achar(nome) == nil {
            let jaTemCartao = carts.contains { norm($0.nome) == norm(nome) }
            ctx.insert(Carteira(nome: jaTemCartao ? "Conta \(nome)" : nome, tipo: .debito, ordem: ordem))
            ordem += 1
        }
        try? ctx.save()
        UserDefaults.standard.set(true, forKey: chave)
    }

    static func saldoAcumulado(_ ctx: ModelContext) {
        let chave = "migracaoSaldoAcumulado-" + (UserDefaults.standard.string(forKey: "uidAtual") ?? "")
        guard !UserDefaults.standard.bool(forKey: chave) else { return }
        let fin = Financas(transacoes: (try? ctx.fetch(FetchDescriptor<Transacao>())) ?? [],
                           contas: (try? ctx.fetch(FetchDescriptor<Conta>())) ?? [],
                           carteiras: (try? ctx.fetch(FetchDescriptor<Carteira>())) ?? [])
        let mes = Mes.indice()
        let ajustes = fin.transacoes(em: mes).filter(\.ehAjuste)
        if !ajustes.isEmpty {
            let liquido = fin.ajustes(em: mes) - fin.abertura(em: mes)
            for t in ajustes { ctx.delete(t) }
            if abs(liquido) >= 0.01 {
                ctx.insert(Transacao(tipo: liquido > 0 ? .receita : .gasto, valor: abs(liquido),
                                     categoria: Transacao.categoriaAjuste, carteira: "",
                                     descricao: "Ajuste de saldo", data: ajustes.map(\.data).max() ?? .now))
            }
            try? ctx.save()
        }
        UserDefaults.standard.set(true, forKey: chave)
    }
}
