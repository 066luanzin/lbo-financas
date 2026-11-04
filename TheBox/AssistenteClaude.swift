import AppIntents
import SwiftData
import Foundation

/// Assistente por voz usando o app do Claude (a assinatura do usuário, sem API):
/// Atalho = Ditar texto → "Preparar pergunta pro Claude" → "Perguntar ao Claude" → "Executar resposta do Claude"
@MainActor
enum Assistente {
    private static func chave(_ s: String) -> String { PlanoCalculo.chave(s) }

    private static func data(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.twoDigits).locale(ptBR))
    }

    /// Instruções + os números do usuário + o que ele falou
    static func pergunta(_ fala: String, ctx: ModelContext) -> String {
        let ts = (try? ctx.fetch(FetchDescriptor<Transacao>(sortBy: [SortDescriptor(\.data, order: .reverse)]))) ?? []
        let carteiras = (try? ctx.fetch(FetchDescriptor<Carteira>(sortBy: [SortDescriptor(\.ordem)]))) ?? []
        let fin = Financas(transacoes: ts,
                           contas: (try? ctx.fetch(FetchDescriptor<Conta>())) ?? [],
                           carteiras: carteiras,
                           limites: (try? ctx.fetch(FetchDescriptor<LimiteMensal>())) ?? [],
                           recorrencias: (try? ctx.fetch(FetchDescriptor<Recorrencia>())) ?? [])
        let cats = ((try? ctx.fetch(FetchDescriptor<Categoria>(sortBy: [SortDescriptor(\.ordem)]))) ?? [])
            .filter { $0.tipo == .gasto }.map(\.nome)
        let hoje = Mes.indice()
        let bancos = fin.bancos()
        let padrao = bancos.first?.nome ?? ""
        var l: [String] = []

        l.append("""
        Você é o assistente financeiro do app LBO Finanças e está falando por voz com o dono do app. \
        Responda em português do Brasil, curto (no máximo 3 frases), sem markdown e sem emoji, do jeito que se fala, \
        porque a resposta vai ser lida em voz alta. Use só os dados abaixo e não invente valores.

        Quando o usuário pedir pra registrar alguma coisa, além da resposta escreva uma linha por ação, exatamente \
        num destes formatos (valor com vírgula, ex.: 30,50):
        #GASTO valor | onde foi | banco | categoria
        #RECEITA valor | de onde veio | banco
        #PAGUEI nome da conta | banco
        #TRANSFERIR valor | banco de onde saiu | banco pra onde foi
        Bancos: \(carteiras.map(\.nome).joined(separator: ", ")). Se ele não disser o banco, use \(padrao).
        Categorias de gasto: \(cats.joined(separator: ", ")).
        Não escreva essas linhas quando for só uma pergunta.
        """)

        l.append("\nDADOS DE HOJE (\(data(.now)))")
        l.append("Na conta hoje (total): \(fin.saldo(em: hoje).moeda)")
        for b in bancos {
            l.append("- \(b.nome): \(fin.saldoCarteira(b.nome, ate: hoje).moeda)")
        }
        let pode = fin.podeGastarHoje()
        if pode.temBase { l.append("Pode gastar hoje: \(pode.resta.moeda)") }
        if let s = OrcamentoDia.situacao(em: .now, transacoes: ts) {
            l.append("Orçamento \(s.nome): gastou \(s.gasto.moeda) de \(s.limite.moeda)")
        }
        l.append("Sobra prevista no fim de \(Mes.nome(hoje).lowercased()): \(fin.saldoPrevisto(em: hoje).moeda)")

        let limite30 = Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
        var pendentes: [String] = []
        for m in hoje...(hoje + 1) {
            for c in fin.contasDoMes(m) where !c.pago(em: m) {
                let venc = c.vencimento(em: m)
                guard venc <= limite30 else { continue }
                let nome = c.parcela(em: m).map { "\(c.nome) (\($0))" } ?? c.nome
                pendentes.append("- \(nome): \(c.valor.moeda), vence \(data(venc))\(c.atrasada(em: m) ? " (ATRASADA)" : "")")
            }
        }
        l.append("Contas que faltam pagar nos próximos 30 dias:")
        l.append(pendentes.isEmpty ? "- nenhuma" : pendentes.joined(separator: "\n"))

        let porCategoria = fin.gastoPorCategoria(em: hoje).sorted { $0.value > $1.value }.prefix(6)
        if !porCategoria.isEmpty {
            l.append("Gastos de \(Mes.nome(hoje).lowercased()) por categoria: "
                     + porCategoria.map { "\($0.key) \($0.value.moeda)" }.joined(separator: ", "))
        }
        let anterior = fin.gastoTotal(em: hoje - 1)
        if anterior > 0 { l.append("Gasto total de \(Mes.nome(hoje - 1).lowercased()): \(anterior.moeda)") }

        let dividas = PlanoCalculo.dividas(fin.contas, hoje: hoje)
        if !dividas.isEmpty {
            let total = dividas.reduce(0) { $0 + $1.total }
            let fim = dividas.map(\.fim).max() ?? hoje
            l.append("Dívidas: \(total.moeda) no total, livre em \(Mes.nome(fim).lowercased()) de \(String(Mes.ano(fim))). "
                     + dividas.map { "\($0.nome) \($0.total.moeda) (\($0.restantes)x)" }.joined(separator: ", "))
        }

        let ultimos = ts.filter { $0.tipo != .transferencia && !$0.ehAjuste }.prefix(8)
        if !ultimos.isEmpty {
            l.append("Últimos lançamentos: " + ultimos.map {
                "\(data($0.data)) \($0.tipo == .receita ? "+" : "-")\($0.valor.moeda) \($0.titulo)"
            }.joined(separator: "; "))
        }

        l.append("\nO QUE O USUÁRIO FALOU: \(fala)")
        return l.joined(separator: "\n")
    }

    private static func valor(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: "R$", with: "").trimmingCharacters(in: .whitespaces)
        if t.contains(",") { return lerValor(t) }
        return Double(t)
    }

    /// Lê a resposta do Claude: executa as linhas #GASTO/#RECEITA/#PAGUEI/#TRANSFERIR e devolve o texto pra falar
    static func executar(_ resposta: String, ctx: ModelContext) -> String {
        let carteiras = (try? ctx.fetch(FetchDescriptor<Carteira>(sortBy: [SortDescriptor(\.ordem)]))) ?? []
        let categorias = (try? ctx.fetch(FetchDescriptor<Categoria>(sortBy: [SortDescriptor(\.ordem)]))) ?? []
        let contas = (try? ctx.fetch(FetchDescriptor<Conta>())) ?? []
        let padrao = carteiras.first { $0.tipo != .credito }?.nome ?? ""

        func banco(_ s: String) -> String {
            let n = chave(s)
            guard !n.isEmpty else { return padrao }
            return carteiras.first { chave($0.nome) == n }?.nome
                ?? carteiras.first { chave($0.nome).contains(n) || n.contains(chave($0.nome)) }?.nome
                ?? padrao
        }

        var fala: [String] = []
        var feitos: [String] = []
        var gastos: [(String, Double)] = []
        let hoje = Mes.indice()

        for bruta in resposta.components(separatedBy: .newlines) {
            let linha = bruta.trimmingCharacters(in: .whitespaces)
            guard !linha.isEmpty else { continue }
            guard linha.hasPrefix("#") else { fala.append(linha); continue }
            let comando = String(linha.dropFirst().prefix { !$0.isWhitespace }).uppercased()
            let partes = linha.dropFirst(comando.count + 1).split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let p: (Int) -> String = { $0 < partes.count ? partes[$0] : "" }

            switch comando {
            case "GASTO":
                guard let v = valor(p(0)), v > 0 else { continue }
                let desc = p(1)
                let cat = categorias.first { $0.tipo == .gasto && chave($0.nome) == chave(p(3)) }?.nome
                    ?? Categorizador.categoria(para: desc, ctx: ctx)
                let cart = banco(p(2))
                ctx.insert(Transacao(tipo: .gasto, valor: v, categoria: cat, carteira: cart, descricao: desc))
                gastos.append((cat, v))
                feitos.append("Anotei \(v.moeda) em \(desc.isEmpty ? cat : desc), no \(cart).")
            case "RECEITA":
                guard let v = valor(p(0)), v > 0 else { continue }
                let desc = p(1)
                let recs = categorias.filter { $0.tipo == .receita }
                let cat = recs.first { !chave(desc).isEmpty && chave(desc).contains(chave($0.nome)) }?.nome
                    ?? recs.first { $0.nome == "Outros" }?.nome ?? recs.first?.nome ?? "Outros"
                let cart = banco(p(2))
                ctx.insert(Transacao(tipo: .receita, valor: v, categoria: cat, carteira: cart, descricao: desc))
                feitos.append("Anotei a entrada de \(v.moeda) no \(cart).")
            case "PAGUEI":
                let n = chave(p(0))
                guard !n.isEmpty else { continue }
                let cart = banco(p(1))
                var achou = false
                for m in hoje...(hoje + 2) where !achou {
                    if let c = contas.first(where: { $0.ocorre(em: m) && !$0.pago(em: m)
                        && (chave($0.nome).contains(n) || n.contains(chave($0.nome))) }) {
                        c.marcarPago(em: m, carteira: cart)
                        feitos.append("Marquei \(c.nome) de \(Mes.nome(m).lowercased()) como paga.")
                        achou = true
                    }
                }
                if !achou { feitos.append("Não achei a conta \(p(0)) pendente.") }
            case "TRANSFERIR":
                guard let v = valor(p(0)), v > 0 else { continue }
                let de = banco(p(1)), para = banco(p(2))
                let t = Transacao(tipo: .transferencia, valor: v, categoria: Transacao.outraConta, carteira: de,
                                  descricao: "Transferência pro \(para)")
                if para != de { t.destino = para }
                ctx.insert(t)
                feitos.append("Passei \(v.moeda) do \(de) pro \(para).")
            default:
                fala.append(linha)
            }
        }
        try? ctx.save()
        for g in gastos { Notificacoes.verificarLimite(categoria: g.0, valor: g.1, data: .now, ctx: ctx) }
        Notificacoes.reagendar(ctx)
        let tudo = (fala + feitos).joined(separator: " ")
        return tudo.isEmpty ? "Não entendi a resposta do Claude." : tudo
    }
}

struct PrepararPerguntaIntent: AppIntent {
    static var title: LocalizedStringResource = "Preparar pergunta pro Claude"
    static var description = IntentDescription("Junta o que você falou com os seus números (saldo, bancos, contas, dívidas) pra mandar pro app do Claude.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "O que você falou")
    var fala: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let container = Store.atual else { throw ErroAtalho(texto: "Entre no LBO Finanças primeiro.") }
        return .result(value: Assistente.pergunta(fala, ctx: container.mainContext))
    }
}

struct ExecutarRespostaIntent: AppIntent {
    static var title: LocalizedStringResource = "Executar resposta do Claude"
    static var description = IntentDescription("Registra o que o Claude mandou (gasto, receita, conta paga, transferência) e devolve a resposta pra falar.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Resposta do Claude")
    var resposta: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let container = Store.atual else { throw ErroAtalho(texto: "Entre no LBO Finanças primeiro.") }
        let texto = Assistente.executar(resposta, ctx: container.mainContext)
        return .result(value: texto, dialog: IntentDialog(stringLiteral: texto))
    }
}
