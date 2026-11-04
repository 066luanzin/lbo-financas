import AppIntents
import SwiftData
import SwiftUI

struct ErroAtalho: Error, CustomLocalizedStringResourceConvertible {
    let texto: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: texto) }
}

struct OpcoesCategoria: DynamicOptionsProvider {
    func results() async throws -> [String] {
        await MainActor.run { () -> [String] in
            guard let c = Store.atual else { return [] }
            let cats = (try? c.mainContext.fetch(FetchDescriptor<Categoria>(sortBy: [SortDescriptor(\.ordem)]))) ?? []
            return cats.filter { $0.tipoRaw == "gasto" }.map(\.nome)
        }
    }
}

struct OpcoesCarteira: DynamicOptionsProvider {
    func results() async throws -> [String] {
        await MainActor.run { () -> [String] in
            guard let c = Store.atual else { return [] }
            let lista = (try? c.mainContext.fetch(FetchDescriptor<Carteira>(sortBy: [SortDescriptor(\.ordem)]))) ?? []
            return lista.map(\.nome)
        }
    }
}

/// Ação "Registrar gasto" do app Atalhos (automação Transação da maquininha)
struct RegistrarGastoIntent: AppIntent {
    static var title: LocalizedStringResource = "Registrar gasto"
    static var description = IntentDescription("Salva um gasto no LBO Finanças.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Valor")
    var valor: Double

    @Parameter(title: "Onde foi?")
    var descricao: String?

    @Parameter(title: "Cartão")
    var cartao: String?

    /// Vazio = o app escolhe sozinho pelo nome do lugar
    @Parameter(title: "Categoria", optionsProvider: OpcoesCategoria())
    var categoria: String?

    /// Vazio = o app usa o cartão informado
    @Parameter(title: "Pagamento", optionsProvider: OpcoesCarteira())
    var pagamento: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Registrar \(\.$valor) em \(\.$descricao)") {
            \.$cartao
            \.$categoria
            \.$pagamento
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let container = Store.atual else {
            throw ErroAtalho(texto: "Entre no LBO Finanças primeiro.")
        }
        let ctx = container.mainContext
        let desc = (descricao ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cat = (categoria ?? "").isEmpty ? Categorizador.categoria(para: desc, ctx: ctx) : (categoria ?? "")
        let pag = (pagamento ?? "").isEmpty ? Categorizador.carteira(para: cartao, ctx: ctx) : (pagamento ?? "")
        ctx.insert(Transacao(tipo: .gasto, valor: abs(valor), categoria: cat, carteira: pag, descricao: desc))
        try ctx.save()
        // Mesmo aviso do app: "R$ 20,00 registrado — Drogasil · Saúde"
        Notificacoes.registrado(valor: abs(valor), titulo: desc.isEmpty ? "Gasto" : desc, categoria: cat)
        Notificacoes.verificarLimite(categoria: cat, valor: abs(valor), data: .now, ctx: ctx)
        Notificacoes.reagendar(ctx)
        return .result()
    }
}

/// Ação "Registrar por texto": lê e-mail ou SMS do banco (Pix, transferência) e registra sozinho
struct RegistrarTextoIntent: AppIntent {
    static var title: LocalizedStringResource = "Registrar por texto"
    static var description = IntentDescription("Lê o texto de um e-mail ou SMS do banco (Pix, transferência, depósito) e registra o gasto ou a receita no LBO Finanças.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Texto")
    var texto: String

    @Parameter(title: "Banco", description: "De qual banco é esse e-mail ou SMS. Em branco, o app tenta descobrir pelo texto.",
               optionsProvider: OpcoesCarteira())
    var banco: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Registrar a partir de \(\.$texto)") { \.$banco }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let container = Store.atual else {
            throw ErroAtalho(texto: "Entre no LBO Finanças primeiro.")
        }
        try LeitorTexto.registrar(texto: texto, ctx: container.mainContext, banco: banco)
        return .result()
    }
}

/// Ação "Registrar comprovante": recebe o comprovante (PDF ou imagem) compartilhado e registra sozinho
struct RegistrarComprovanteIntent: AppIntent {
    static var title: LocalizedStringResource = "Registrar comprovante"
    static var description = IntentDescription("Lê um comprovante de Pix ou transferência (PDF ou imagem) e registra o gasto ou a receita no LBO Finanças.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Comprovante", supportedTypeIdentifiers: ["public.image", "com.adobe.pdf"],
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var arquivo: IntentFile

    @Parameter(title: "Banco", description: "De qual banco saiu (ou entrou) o dinheiro.",
               optionsProvider: OpcoesCarteira())
    var banco: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Registrar \(\.$arquivo)") { \.$banco }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let container = Store.atual else {
            throw ErroAtalho(texto: "Entre no LBO Finanças primeiro.")
        }
        let texto = await LeitorArquivo.texto(de: arquivo)
        try LeitorTexto.registrar(texto: texto, ctx: container.mainContext, foto: LeitorArquivo.foto(de: arquivo), banco: banco)
        return .result()
    }
}

/// Abre o app direto na tela de registrar (usado no toque duplo nas costas)
struct NovoRegistroIntent: AppIntent {
    static var title: LocalizedStringResource = "Novo registro"
    static var description = IntentDescription("Abre o LBO Finanças na tela de registrar um gasto.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppState.shared.abrirRegistro = true
        return .result()
    }
}

/// "Quanto posso gastar hoje": resposta rápida pela Siri ou pelo widget do app Atalhos
struct QuantoPossoGastarIntent: AppIntent {
    static var title: LocalizedStringResource = "Quanto posso gastar hoje"
    static var description = IntentDescription("Mostra quanto ainda dá pra gastar hoje, o orçamento da semana e o saldo da conta.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard let container = Store.atual else {
            throw ErroAtalho(texto: "Entre no LBO Finanças primeiro.")
        }
        let ctx = container.mainContext
        let ts = (try? ctx.fetch(FetchDescriptor<Transacao>())) ?? []
        let fin = Financas(transacoes: ts,
                           contas: (try? ctx.fetch(FetchDescriptor<Conta>())) ?? [],
                           carteiras: (try? ctx.fetch(FetchDescriptor<Carteira>())) ?? [],
                           limites: (try? ctx.fetch(FetchDescriptor<LimiteMensal>())) ?? [],
                           recorrencias: (try? ctx.fetch(FetchDescriptor<Recorrencia>())) ?? [])
        let r = fin.podeGastarHoje()
        let mes = Mes.indice()
        let orc = OrcamentoDia.situacao(em: .now, transacoes: ts)
        var frase = !r.temBase
            ? "Registre seu salário ou ajuste o saldo pra eu calcular quanto você pode gastar."
            : (r.resta >= 0 ? "Hoje você ainda pode gastar \(r.resta.moeda)." : "Hoje você já passou \(abs(r.resta).moeda) do que podia.")
        if let orc {
            let resta = orc.limite - orc.gasto
            frase += resta >= 0 ? " Resta \(resta.moeda) do orçamento \(orc.nome)." : " Passou \(abs(resta).moeda) do orçamento \(orc.nome)."
        }
        return .result(dialog: IntentDialog(stringLiteral: frase),
                       view: ResumoAtalho(podeHoje: r.temBase ? r.resta : nil,
                                          orcamento: orc.map { ($0.limite - $0.gasto, $0.nome) },
                                          naConta: fin.saldo(em: mes),
                                          sobra: fin.saldoPrevisto(em: mes)))
    }
}

/// O cartãozinho que aparece na Siri / no Atalhos
struct ResumoAtalho: View {
    let podeHoje: Double?
    let orcamento: (Double, String)?
    let naConta: Double
    let sobra: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            linha("Pode gastar hoje", podeHoje.map { $0.moeda } ?? "—", (podeHoje ?? 0) < 0 ? .orange : .green)
            if let orcamento {
                linha("Orçamento \(orcamento.1)", (orcamento.0 < 0 ? "-" : "") + abs(orcamento.0).moeda, orcamento.0 < 0 ? .red : .primary)
            }
            linha("Na conta hoje", naConta.moeda, naConta < 0 ? .red : .primary)
            linha("Sobra no fim do mês", sobra.moeda, sobra < 0 ? .red : .primary)
        }
        .padding(16)
    }

    private func linha(_ titulo: String, _ valor: String, _ cor: Color) -> some View {
        HStack {
            Text(titulo).font(.system(size: 14)).foregroundStyle(.secondary)
            Spacer()
            Text(valor).font(.system(size: 16, weight: .bold)).foregroundStyle(cor)
        }
    }
}

struct LBOAtalhos: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuantoPossoGastarIntent(),
            phrases: [
                "Quanto posso gastar no \(.applicationName)",
                "Quanto posso gastar hoje no \(.applicationName)",
                "Meu saldo no \(.applicationName)"
            ],
            shortTitle: "Quanto posso gastar",
            systemImageName: "banknote"
        )
        AppShortcut(
            intent: NovoRegistroIntent(),
            phrases: [
                "Novo registro no \(.applicationName)",
                "Registrar no \(.applicationName)"
            ],
            shortTitle: "Novo registro",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: GasteiIntent(),
            phrases: [
                "Gastei no \(.applicationName)",
                "Anota um gasto no \(.applicationName)",
                "Registrar gasto no \(.applicationName)"
            ],
            shortTitle: "Gastei",
            systemImageName: "mic"
        )
    }
}

/// "E aí Siri, gastei no LBO Finanças" → pergunta o valor e onde foi, escolhe a categoria sozinho
struct GasteiIntent: AppIntent {
    static var title: LocalizedStringResource = "Gastei"
    static var description = IntentDescription("Registra um gasto falando com a Siri: ela pergunta quanto foi e onde.")
    static var openAppWhenRun: Bool = false

    /// Texto livre ("25 reais", "vinte e cinco e cinquenta"): a Siri entrega a frase e o app entende o valor
    @Parameter(title: "Valor", requestValueDialog: IntentDialog("Quanto você gastou?"))
    var valor: String

    @Parameter(title: "Onde foi", requestValueDialog: IntentDialog("Onde foi?"))
    var onde: String

    static var parameterSummary: some ParameterSummary {
        Summary("Gastei \(\.$valor) em \(\.$onde)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let container = Store.atual else {
            throw ErroAtalho(texto: "Entre no LBO Finanças primeiro.")
        }
        let ctx = container.mainContext
        let desc = onde.trimmingCharacters(in: .whitespacesAndNewlines)
        let cat = Categorizador.categoria(para: desc, ctx: ctx)
        let carteiras = (try? ctx.fetch(FetchDescriptor<Carteira>(sortBy: [SortDescriptor(\.ordem)]))) ?? []
        let cart = carteiras.first { $0.tipo == .dinheiro }?.nome ?? carteiras.first { $0.tipo == .pix }?.nome ?? ""
        guard let lido = LeitorFala.valor(valor), lido > 0 else {
            throw ErroAtalho(texto: "Não entendi o valor. Diga só o número, por exemplo: vinte e cinco, ou doze e noventa.")
        }
        let v = abs(lido)
        ctx.insert(Transacao(tipo: .gasto, valor: v, categoria: cat, carteira: cart, descricao: desc))
        try ctx.save()
        Notificacoes.verificarLimite(categoria: cat, valor: v, data: .now, ctx: ctx)
        Notificacoes.reagendar(ctx)
        return .result(dialog: IntentDialog(stringLiteral: "Anotado: \(v.moeda) em \(desc.isEmpty ? cat : desc), categoria \(cat)."))
    }
}
