import Foundation
import SwiftData
import Supabase

/// Mudanças feitas no site (LBO Finanças Web): o app aplica quando abre e apaga da tabela "pedidos".
/// Cada pedido tem um tipo (gasto, conta_salvar, ajuste...) e os campos que ele usa.
@MainActor
enum Pedidos {
    struct Dados: Decodable {
        var chave: String?
        var valor: Double?
        var descricao: String?
        var banco: String?
        var categoria: String?
        /// "2026-11-04"
        var data: String?
        var destino: String?
        var conta: String?
        var mes: Int?
        /// editar/apagar transação de backup antigo (sem chave): como ela estava
        var original: Original?
        // contas
        var nome: String?
        var dia: Int?
        var venceMesSeguinte: Bool?
        /// "fixa", "unica" ou "parcelada"
        var tipoConta: String?
        var parcelaAtual: Int?
        var totalParcelas: Int?
        var inicio: Int?
        var juros: Double?
        var soMes: Bool?
        // saldo
        var real: Double?
        var reais: [String: Double]?
        // caixinhas
        var caixinha: String?
        var entrada: Bool?
        var meta: Double?
        /// "2027-06-30" ou vazio
        var prazo: String?
        var saldoInicial: Double?
        // categorias, carteiras, receitas fixas
        var tipo: String?
        var limite: Double?
        var essencial: Bool?
        var diaVencimento: Int?
        var diaFechamento: Int?
        var ativa: Bool?
        // orçamento do dia a dia
        var ativo: Bool?
        var modo: String?
        var dias: [Double]?
        var semana: Double?
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
        var aplicador = Aplicador(ctx: ctx)
        var novos = 0
        for p in lista where !aplicados.contains(p.id) {
            aplicador.aplicar(p)
            try? ctx.save()
            aplicados.insert(p.id)
            novos += 1
        }
        d.set(Array(aplicados), forKey: chaveAplicados)

        // apaga do Supabase; se não der agora, fica marcado como aplicado pra não repetir
        for p in lista {
            if (try? await Nuvem.client.from("pedidos").delete().eq("id", value: p.id).execute()) != nil {
                aplicados.remove(p.id)
            }
        }
        d.set(Array(aplicados), forKey: chaveAplicados)

        guard novos > 0 else { return }
        for g in aplicador.gastos { Notificacoes.verificarLimite(categoria: g.0, valor: g.1, data: g.2, ctx: ctx) }
        Notificacoes.reagendar(ctx)
        Notificacoes.agora("\(novos) \(novos == 1 ? "mudança" : "mudanças") do site", "Já estão no app.")
        _ = await Backup.enviar(ctx, forcar: true)
    }

    /// Aplica um pedido de cada vez, sempre lendo o banco de novo (um pedido pode depender do anterior)
    private struct Aplicador {
        let ctx: ModelContext
        var gastos: [(String, Double, Date)] = []
        let formato: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()

        init(ctx: ModelContext) { self.ctx = ctx }

        private func todos<T: PersistentModel>(_ tipo: T.Type) -> [T] { (try? ctx.fetch(FetchDescriptor<T>())) ?? [] }
        private var carteiras: [Carteira] {
            (try? ctx.fetch(FetchDescriptor<Carteira>(sortBy: [SortDescriptor(\.ordem)]))) ?? []
        }
        private var categorias: [Categoria] {
            (try? ctx.fetch(FetchDescriptor<Categoria>(sortBy: [SortDescriptor(\.ordem)]))) ?? []
        }
        private func normal(_ s: String) -> String { PlanoCalculo.chave(s) }
        private func uuid(_ s: String?) -> UUID? { s.flatMap(UUID.init(uuidString:)) }

        private func banco(_ s: String?) -> String {
            let lista = carteiras
            let padrao = lista.first { $0.tipo != .credito }?.nome ?? ""
            guard let s, !s.isEmpty else { return padrao }
            return lista.first { normal($0.nome) == normal(s) }?.nome ?? padrao
        }

        private func data(_ s: String?) -> Date {
            guard let s, let dia = formato.date(from: s) else { return .now }
            if Calendar.current.isDateInToday(dia) { return .now }
            return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: dia) ?? dia
        }

        private func transacao(_ x: Dados) -> Transacao? {
            let lista = todos(Transacao.self)
            if let k = uuid(x.chave), let t = lista.first(where: { $0.chave == k }) { return t }
            guard let o = x.original, let quando = o.data, let v = o.valor else { return nil }
            return lista.first {
                abs($0.data.timeIntervalSince1970 - quando) < 1 && abs($0.valor - v) < 0.005
                    && $0.descricao == (o.descricao ?? "") && (o.tipo == nil || $0.tipoRaw == o.tipo)
            }
        }

        private func conta(_ x: Dados) -> Conta? {
            let lista = todos(Conta.self)
            if let k = uuid(x.chave), let c = lista.first(where: { $0.chave == k }) { return c }
            guard let nome = x.conta, let mes = x.mes else { return nil }
            return lista.first { $0.nome == nome && $0.ocorre(em: mes) && !$0.pago(em: mes) }
        }

        private func categoriaValida(_ nome: String?, tipo: TipoTransacao) -> String? {
            guard let nome else { return nil }
            return categorias.first { $0.tipo == tipo && $0.nome == nome }?.nome
        }

        mutating func aplicar(_ p: Pedido) {
            let x = p.dados
            let desc = (x.descricao ?? "").trimmingCharacters(in: .whitespaces)
            let hoje = Mes.indice()
            switch p.tipo {

            // ---------- transações ----------
            case "gasto":
                guard let v = x.valor, v > 0 else { return }
                let cat = categoriaValida(x.categoria, tipo: .gasto) ?? Categorizador.categoria(para: desc, ctx: ctx)
                let quando = data(x.data)
                ctx.insert(Transacao(tipo: .gasto, valor: v, categoria: cat, carteira: banco(x.banco), descricao: desc, data: quando))
                gastos.append((cat, v, quando))
            case "receita":
                guard let v = x.valor, v > 0 else { return }
                let recs = categorias.filter { $0.tipo == .receita }
                let cat = categoriaValida(x.categoria, tipo: .receita)
                    ?? recs.first { $0.nome == "Outros" }?.nome ?? recs.first?.nome ?? "Outros"
                ctx.insert(Transacao(tipo: .receita, valor: v, categoria: cat, carteira: banco(x.banco), descricao: desc,
                                     data: data(x.data)))
            case "transferir":
                guard let v = x.valor, v > 0 else { return }
                let de = banco(x.banco), para = banco(x.destino)
                let t = Transacao(tipo: .transferencia, valor: v, categoria: Transacao.outraConta, carteira: de,
                                  descricao: desc.isEmpty ? "Transferência pro \(para)" : desc, data: data(x.data))
                if para != de { t.destino = para }
                ctx.insert(t)
            case "editar":
                guard let t = transacao(x) else { return }
                if let v = x.valor, v > 0 { t.valor = v }
                if x.descricao != nil { t.descricao = desc }
                if let cat = categoriaValida(x.categoria, tipo: t.tipo) { t.categoria = cat }
                if let b = x.banco, !b.isEmpty { t.carteira = banco(b) }
                if let s = x.data, let dia = formato.date(from: s), !Calendar.current.isDate(dia, inSameDayAs: t.data) {
                    t.data = data(s)
                }
            case "apagar":
                if let t = transacao(x) { ctx.delete(t) }

            // ---------- contas ----------
            case "paguei":
                guard let mes = x.mes, let c = conta(x) else { return }
                c.marcarPago(em: mes, carteira: banco(x.banco))
            case "desmarcar":
                guard let mes = x.mes, let c = conta(x) else { return }
                c.desmarcar(em: mes)
            case "conta_salvar":
                guard let nome = x.nome?.trimmingCharacters(in: .whitespaces), !nome.isEmpty,
                      let v = x.valor, v > 0 else { return }
                let tipo = x.tipoConta ?? "fixa"
                let parcelada = tipo == "parcelada" && (x.totalParcelas ?? 0) > 0
                let c: Conta
                if let existente = uuid(x.chave).flatMap({ k in todos(Conta.self).first { $0.chave == k } }) {
                    c = existente
                } else {
                    c = Conta(nome: nome, valor: v, dia: 10, venceMesSeguinte: false, categoria: "", repetir: true,
                              parcelaAtual: 0, totalParcelas: 0, inicio: x.inicio ?? hoje)
                    ctx.insert(c)
                }
                c.nome = nome
                c.valor = v
                c.dia = min(max(x.dia ?? c.dia, 1), 31)
                c.venceMesSeguinte = x.venceMesSeguinte ?? c.venceMesSeguinte
                c.categoria = categoriaValida(x.categoria, tipo: .gasto) ?? (x.categoria ?? c.categoria)
                c.repetir = tipo == "fixa"
                c.totalParcelas = parcelada ? (x.totalParcelas ?? 0) : 0
                c.parcelaAtual = parcelada ? max(x.parcelaAtual ?? 1, 1) : 0
                if let i = x.inicio { c.inicio = i }
                c.juros = max(x.juros ?? c.juros, 0)
            case "conta_apagar":
                guard let c = conta(x) else { return }
                if x.soMes == true, let mes = x.mes { c.excluir(em: mes) } else { ctx.delete(c) }

            // ---------- saldo ----------
            case "ajuste":
                guard let real = x.real else { return }
                let fin = Financas.carregar(ctx)
                let carteira = (x.banco ?? "").isEmpty ? "" : banco(x.banco)
                let atual = carteira.isEmpty ? fin.saldo(em: hoje) : fin.saldoCarteira(carteira, ate: hoje)
                Ajuste.igualar(real: real, atual: atual, carteira: carteira, mes: hoje, fin: fin, ctx: ctx)
            case "ajuste_bancos":
                guard let reais = x.reais, !reais.isEmpty else { return }
                var certos: [String: Double] = [:]
                for (nome, v) in reais { certos[banco(nome)] = v }
                Ajuste.igualarBancos(certos, ctx: ctx)

            // ---------- quitar ----------
            case "adiantar", "quitar":
                guard let nome = x.nome else { return }
                let dividas = PlanoCalculo.dividas(todos(Conta.self), hoje: hoje)
                guard let divida = dividas.first(where: { normal($0.nome) == normal(nome) }) else { return }
                if p.tipo == "adiantar" {
                    PlanoCalculo.adiantar(divida, ctx: ctx)
                } else if let v = x.valor, v > 0 {
                    PlanoCalculo.quitarAVista(divida, valor: v, ctx: ctx)
                }

            // ---------- análise ----------
            case "limite_mes":
                guard let mes = x.mes, let v = x.valor, v >= 0 else { return }
                if let l = todos(LimiteMensal.self).first(where: { $0.mes == mes }) { l.valor = v } else {
                    ctx.insert(LimiteMensal(mes: mes, valor: v))
                }

            // ---------- categorias ----------
            case "categoria_salvar":
                guard let nome = x.nome?.trimmingCharacters(in: .whitespaces), !nome.isEmpty else { return }
                if let c = uuid(x.chave).flatMap({ k in categorias.first { $0.chave == k } }) {
                    if c.nome != nome {
                        let antigo = c.nome
                        for t in todos(Transacao.self) where t.categoria == antigo && t.tipo == c.tipo { t.categoria = nome }
                        if c.tipo == .gasto { for conta in todos(Conta.self) where conta.categoria == antigo { conta.categoria = nome } }
                        if c.tipo == .receita { for r in todos(Recorrencia.self) where r.categoria == antigo { r.categoria = nome } }
                        c.nome = nome
                    }
                    if let l = x.limite { c.limite = max(l, 0) }
                    if let e = x.essencial { c.essencial = e }
                } else {
                    let tipo = TipoTransacao(rawValue: x.tipo ?? "gasto") ?? .gasto
                    guard !categorias.contains(where: { $0.tipo == tipo && normal($0.nome) == normal(nome) }) else { return }
                    let ordem = (categorias.filter { $0.tipo == tipo }.map(\.ordem).max() ?? 0) + 1
                    ctx.insert(Categoria(nome: nome, icone: Categoria.iconePadrao(nome), tipo: tipo,
                                         limite: max(x.limite ?? 0, 0), essencial: x.essencial ?? true, ordem: ordem))
                }
            case "categoria_apagar":
                if let c = uuid(x.chave).flatMap({ k in categorias.first { $0.chave == k } }) { ctx.delete(c) }

            // ---------- carteiras / bancos ----------
            case "carteira_salvar":
                guard let nome = x.nome?.trimmingCharacters(in: .whitespaces), !nome.isEmpty else { return }
                let tipo = TipoCarteira(rawValue: x.tipo ?? "debito") ?? .debito
                if let c = uuid(x.chave).flatMap({ k in carteiras.first { $0.chave == k } }) {
                    if c.nome != nome {
                        let antigo = c.nome
                        for t in todos(Transacao.self) {
                            if t.carteira == antigo { t.carteira = nome }
                            if t.destino == antigo { t.destino = nome }
                        }
                        for r in todos(Recorrencia.self) where r.carteira == antigo { r.carteira = nome }
                        for conta in todos(Conta.self) {
                            conta.pagamentos = conta.pagamentos.map {
                                var e = $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                                if e.count > 1 && e[1] == antigo { e[1] = nome }
                                return e.joined(separator: "|")
                            }
                        }
                        c.nome = nome
                    }
                    c.tipoRaw = tipo.rawValue
                    if let dv = x.diaVencimento { c.diaVencimento = min(max(dv, 1), 31) }
                    c.diaFechamento = tipo == .credito ? min(max(x.diaFechamento ?? c.diaFechamento, 0), 31) : 0
                } else {
                    guard !carteiras.contains(where: { normal($0.nome) == normal(nome) }) else { return }
                    let nova = Carteira(nome: nome, tipo: tipo, diaVencimento: min(max(x.diaVencimento ?? 10, 1), 31),
                                        ordem: (carteiras.map(\.ordem).max() ?? 0) + 1)
                    nova.diaFechamento = tipo == .credito ? min(max(x.diaFechamento ?? 0, 0), 31) : 0
                    ctx.insert(nova)
                }
            case "carteira_apagar":
                if let c = uuid(x.chave).flatMap({ k in carteiras.first { $0.chave == k } }) { ctx.delete(c) }

            // ---------- receitas fixas ----------
            case "receita_fixa_salvar":
                guard let nome = x.nome?.trimmingCharacters(in: .whitespaces), !nome.isEmpty,
                      let v = x.valor, v > 0 else { return }
                let dia = min(max(x.dia ?? 5, 1), 31)
                let recs = categorias.filter { $0.tipo == .receita }
                let cat = categoriaValida(x.categoria, tipo: .receita)
                    ?? recs.first { $0.nome == "Salário" }?.nome ?? recs.first?.nome ?? "Outros"
                if let r = uuid(x.chave).flatMap({ k in todos(Recorrencia.self).first { $0.chave == k } }) {
                    r.nome = nome
                    r.valor = v
                    r.dia = dia
                    r.categoria = cat
                    if let b = x.banco { r.carteira = banco(b) }
                    if let a = x.ativa {
                        if a && !r.ativa { r.ultimoMes = max(r.ultimoMes, hoje - 1) }
                        r.ativa = a
                    }
                } else {
                    // se o dia já passou neste mês, considera que a deste mês já entrou
                    let jaPassou = Calendar.current.component(.day, from: .now) >= dia
                    let nova = Recorrencia(nome: nome, valor: v, dia: dia, categoria: cat, carteira: banco(x.banco),
                                           ultimoMes: jaPassou ? hoje : hoje - 1)
                    nova.ativa = x.ativa ?? true
                    ctx.insert(nova)
                }
            case "receita_fixa_apagar":
                if let r = uuid(x.chave).flatMap({ k in todos(Recorrencia.self).first { $0.chave == k } }) { ctx.delete(r) }

            // ---------- caixinhas ----------
            case "caixinha_salvar":
                guard let nome = x.nome?.trimmingCharacters(in: .whitespaces), !nome.isEmpty else { return }
                let prazo = x.prazo.flatMap { formato.date(from: $0) }
                let caixinhas = todos(Caixinha.self)
                if let c = uuid(x.chave).flatMap({ k in caixinhas.first { $0.chave == k } }) {
                    if c.nome != nome {
                        let antigo = Transacao.prefixoCaixinha + c.nome
                        for t in todos(Transacao.self) where t.categoria == antigo { t.categoria = Transacao.prefixoCaixinha + nome }
                        c.nome = nome
                    }
                    if let m = x.meta { c.meta = max(m, 0) }
                    if let s = x.saldoInicial { c.saldoInicial = max(s, 0) }
                    if x.prazo != nil { c.prazo = prazo }
                } else {
                    ctx.insert(Caixinha(nome: nome, meta: max(x.meta ?? 0, 0), saldoInicial: max(x.saldoInicial ?? 0, 0),
                                        prazo: prazo, ordem: (caixinhas.map(\.ordem).max() ?? 0) + 1))
                }
            case "caixinha_apagar":
                if let c = uuid(x.chave).flatMap({ k in todos(Caixinha.self).first { $0.chave == k } }) { ctx.delete(c) }
            case "caixinha_mov":
                guard let nome = x.caixinha, let v = x.valor, v > 0 else { return }
                let resgate = x.entrada ?? false
                ctx.insert(Transacao(tipo: .transferencia, valor: v, categoria: Transacao.prefixoCaixinha + nome,
                                     carteira: banco(x.banco), descricao: (resgate ? "Resgate: " : "Guardado: ") + nome,
                                     data: data(x.data), entrada: resgate))

            // ---------- orçamento do dia a dia ----------
            case "orcamento":
                let d = UserDefaults.standard
                if let a = x.ativo { d.set(a, forKey: "orcAtivo") }
                if let m = x.modo, m == "dia" || m == "semana" { d.set(m, forKey: "orcModo") }
                if let dias = x.dias, dias.count == 7 { d.set(dias.map { max($0, 0) }, forKey: "orcDias") }
                if let s = x.semana { d.set(max(s, 0), forKey: "orcSemana") }

            default:
                break
            }
        }
    }
}
