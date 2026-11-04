import Foundation
import SwiftData
import Supabase

/// Lançamentos feitos no site (LBO Finanças Web): o app aplica quando abre e apaga da tabela "pedidos"
@MainActor
enum Pedidos {
    struct Dados: Decodable {
        var valor: Double?
        var descricao: String?
        var banco: String?
        var categoria: String?
        /// "2026-11-04"
        var data: String?
        var destino: String?
        var conta: String?
        var mes: Int?
        /// editar/apagar: a transação como estava no backup
        var original: Original?
    }

    struct Original: Decodable {
        var data: Double?
        var valor: Double?
        var descricao: String?
        var tipo: String?
    }

    struct Pedido: Decodable {
        var id: String
        var tipo: String
        var dados: Dados
    }

    private static let chaveAplicados = "pedidosAplicados"

    static func aplicar(_ ctx: ModelContext) async {
        guard await Backup.temSessao() else { return }
        let resposta: [Pedido]? = try? await Nuvem.client.from("pedidos")
            .select("id, tipo, dados").order("criado_em").execute().value
        guard let lista = resposta, !lista.isEmpty else { return }

        let d = UserDefaults.standard
        var aplicados = Set(d.stringArray(forKey: chaveAplicados) ?? [])
        let carteiras = (try? ctx.fetch(FetchDescriptor<Carteira>(sortBy: [SortDescriptor(\.ordem)]))) ?? []
        let categorias = (try? ctx.fetch(FetchDescriptor<Categoria>(sortBy: [SortDescriptor(\.ordem)]))) ?? []
        let contas = (try? ctx.fetch(FetchDescriptor<Conta>())) ?? []
        let transacoes = (try? ctx.fetch(FetchDescriptor<Transacao>())) ?? []
        func achar(_ o: Original?) -> Transacao? {
            guard let o, let quando = o.data, let v = o.valor else { return nil }
            return transacoes.first {
                abs($0.data.timeIntervalSince1970 - quando) < 1 && abs($0.valor - v) < 0.005
                    && $0.descricao == (o.descricao ?? "") && (o.tipo == nil || $0.tipoRaw == o.tipo)
            }
        }
        let padrao = carteiras.first { $0.tipo != .credito }?.nome ?? ""
        let normal: (String) -> String = { PlanoCalculo.chave($0) }
        func banco(_ s: String?) -> String {
            guard let s, !s.isEmpty else { return padrao }
            return carteiras.first { normal($0.nome) == normal(s) }?.nome ?? padrao
        }
        let formato = DateFormatter()
        formato.locale = Locale(identifier: "en_US_POSIX")
        formato.dateFormat = "yyyy-MM-dd"
        func data(_ s: String?) -> Date {
            guard let s, let dia = formato.date(from: s) else { return .now }
            if Calendar.current.isDateInToday(dia) { return .now }
            return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: dia) ?? dia
        }

        var novos = 0
        var gastos: [(String, Double, Date)] = []
        for p in lista where !aplicados.contains(p.id) {
            let x = p.dados
            let desc = (x.descricao ?? "").trimmingCharacters(in: .whitespaces)
            switch p.tipo {
            case "gasto":
                guard let v = x.valor, v > 0 else { break }
                let cat = categorias.first { $0.tipo == .gasto && $0.nome == x.categoria }?.nome
                    ?? Categorizador.categoria(para: desc, ctx: ctx)
                let quando = data(x.data)
                ctx.insert(Transacao(tipo: .gasto, valor: v, categoria: cat, carteira: banco(x.banco), descricao: desc, data: quando))
                gastos.append((cat, v, quando))
            case "receita":
                guard let v = x.valor, v > 0 else { break }
                let recs = categorias.filter { $0.tipo == .receita }
                let cat = recs.first { $0.nome == x.categoria }?.nome
                    ?? recs.first { $0.nome == "Outros" }?.nome ?? recs.first?.nome ?? "Outros"
                ctx.insert(Transacao(tipo: .receita, valor: v, categoria: cat, carteira: banco(x.banco), descricao: desc,
                                     data: data(x.data)))
            case "transferir":
                guard let v = x.valor, v > 0 else { break }
                let de = banco(x.banco), para = banco(x.destino)
                let t = Transacao(tipo: .transferencia, valor: v, categoria: Transacao.outraConta, carteira: de,
                                  descricao: desc.isEmpty ? "Transferência pro \(para)" : desc, data: data(x.data))
                if para != de { t.destino = para }
                ctx.insert(t)
            case "paguei":
                guard let nome = x.conta, let mes = x.mes,
                      let c = contas.first(where: { $0.nome == nome && $0.ocorre(em: mes) && !$0.pago(em: mes) }) else { break }
                c.marcarPago(em: mes, carteira: banco(x.banco))
            case "editar":
                guard let t = achar(x.original) else { break }
                if let v = x.valor, v > 0 { t.valor = v }
                t.descricao = desc
                if let cat = x.categoria, categorias.contains(where: { $0.nome == cat && $0.tipo == t.tipo }) { t.categoria = cat }
                if let b = x.banco, !b.isEmpty { t.carteira = banco(b) }
                if let s = x.data, let dia = formato.date(from: s), !Calendar.current.isDate(dia, inSameDayAs: t.data) {
                    t.data = data(s)
                }
            case "apagar":
                if let t = achar(x.original) { ctx.delete(t) }
            default:
                break
            }
            aplicados.insert(p.id)
            novos += 1
        }
        try? ctx.save()
        d.set(Array(aplicados), forKey: chaveAplicados)

        // apaga do Supabase; se não der agora, fica marcado como aplicado pra não repetir
        for p in lista {
            if (try? await Nuvem.client.from("pedidos").delete().eq("id", value: p.id).execute()) != nil {
                aplicados.remove(p.id)
            }
        }
        d.set(Array(aplicados), forKey: chaveAplicados)

        guard novos > 0 else { return }
        for g in gastos { Notificacoes.verificarLimite(categoria: g.0, valor: g.1, data: g.2, ctx: ctx) }
        Notificacoes.reagendar(ctx)
        Notificacoes.agora("\(novos) \(novos == 1 ? "lançamento" : "lançamentos") do site", "Já estão no app.")
        _ = await Backup.enviar(ctx, forcar: true)
    }
}
