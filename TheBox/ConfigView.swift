import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ConfigView: View {
    enum Folha: String, Identifiable {
        case nome, tema, catGasto, catReceita, carteiras, moeda, toqueDuplo, maquininha, pix, fixas, widget, lista
        var id: String { rawValue }
    }

    @Environment(\.modelContext) private var ctx
    @Environment(Sessao.self) private var sessao
    @Query(sort: \Categoria.ordem) private var categorias: [Categoria]
    @Query(sort: \Carteira.ordem) private var carteiras: [Carteira]
    @Query(sort: \Transacao.data, order: .reverse) private var transacoes: [Transacao]
    @AppStorage("nomeUsuario") private var nome = ""
    @AppStorage("emailUsuario") private var email = ""
    @AppStorage("tema") private var tema = "sistema"
    @AppStorage("moeda") private var moeda = "BRL"
    @AppStorage("avisoContas") private var avisoContas = true
    @AppStorage("lembreteRegistro") private var lembreteRegistro = true
    @AppStorage("horaLembrete") private var horaLembrete = 20
    @AppStorage("resumoSemana") private var resumoSemana = true
    @AppStorage("alertasInteligentes") private var alertas = true
    @AppStorage("faceID") private var faceID = false

    @State private var folha: Folha?
    @State private var exportar: ArquivoExportado?
    @State private var importar = false
    @State private var mensagem: String?
    @State private var confirmarSair = false
    @State private var confirmarExcluir = false

    private var iniciais: String {
        let partes = nome.split(separator: " ").prefix(2)
        let r = partes.compactMap { $0.first }.map { String($0) }.joined().uppercased()
        return r.isEmpty ? "?" : r
    }
    private var nomeTema: String { ["claro": "Claro", "escuro": "Escuro"][tema] ?? "Sistema" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Cabecalho(sub: "Preferências", titulo: "Config")
                    .padding(.bottom, 20)

                Button { folha = .nome } label: {
                    HStack(spacing: 18) {
                        Text(iniciais)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(Color.sobreDestaque)
                            .frame(width: 72, height: 72)
                            .background(Color.destaque, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(nome.isEmpty ? "Seu nome" : nome).font(.system(size: 16, weight: .semibold))
                            Text("Toque para editar").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .cartao(18)
                }
                .buttonStyle(.plain)

                secoesPreferencias
                secoesSistema

                LinhaConfig(titulo: "Excluir conta", icone: "trash", perigo: true) { confirmarExcluir = true }
                    .padding(.horizontal, 22)
                    .background(Color.cartao, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.borda))
                    .padding(.top, 16)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(Color.fundo)
        .onChange(of: avisoContas) { _, _ in Notificacoes.reagendar(ctx) }
        .onChange(of: lembreteRegistro) { _, _ in Notificacoes.reagendar(ctx) }
        .onChange(of: horaLembrete) { _, _ in Notificacoes.reagendar(ctx) }
        .onChange(of: resumoSemana) { _, _ in Notificacoes.reagendar(ctx) }
        .onChange(of: faceID) { _, ligado in
            if ligado {
                Task { if !(await Biometria.autenticar()) { faceID = false } }
            }
        }
        .sheet(item: $folha) { f in
            switch f {
            case .nome: NomeSheet(nome: $nome)
            case .tema: TemaSheet(tema: $tema)
            case .catGasto: CategoriasSheet(tipo: .gasto)
            case .catReceita: CategoriasSheet(tipo: .receita)
            case .carteiras: CarteirasSheet()
            case .moeda: MoedaSheet(moeda: $moeda)
            case .toqueDuplo: GuiaView(guia: .toqueDuplo)
            case .maquininha: GuiaView(guia: .maquininha)
            case .pix: GuiaView(guia: .pix)
            case .widget: GuiaView(guia: .widget)
            case .lista: SubstituirContasSheet()
            case .fixas: ReceitasFixasSheet()
            }
        }
        .sheet(item: $exportar) { a in Compartilhar(itens: [a.url]) }
        .fileImporter(isPresented: $importar, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { resultado in
            if case let .success(url) = resultado {
                let n = CSV.importar(url, ctx: ctx)
                mensagem = n > 0 ? "\(n) transações importadas." : "Nenhuma transação encontrada no arquivo."
            }
        }
        .alert(mensagem ?? "", isPresented: Binding(get: { mensagem != nil }, set: { if !$0 { mensagem = nil } })) {
            Button("OK") { mensagem = nil }
        }
        .confirmationDialog("Sair da sua conta?", isPresented: $confirmarSair, titleVisibility: .visible) {
            Button("Sair", role: .destructive) { Task { await sessao.sair() } }
        } message: {
            Text("Seus dados continuam salvos neste iPhone e voltam quando você entrar de novo.")
        }
        .confirmationDialog("Excluir sua conta?", isPresented: $confirmarExcluir, titleVisibility: .visible) {
            Button("Excluir conta e dados", role: .destructive) {
                Task {
                    do { try await sessao.excluirConta() } catch { mensagem = Sessao.mensagem(error) }
                }
            }
        } message: {
            Text("Isso apaga sua conta e todos os dados deste iPhone. Não dá pra desfazer.")
        }
    }

    @ViewBuilder
    private var secoesPreferencias: some View {
                Secao("Aparência") {
                    LinhaConfig(titulo: "Tema", valor: nomeTema) { folha = .tema }
                }

                Secao("Registro") {
                    LinhaConfig(titulo: "Categorias de gasto",
                                valor: "\(categorias.filter { $0.tipo == .gasto }.count) ativas") { folha = .catGasto }
                    Divisor()
                    LinhaConfig(titulo: "Categorias de receita",
                                valor: "\(categorias.filter { $0.tipo == .receita }.count) ativas") { folha = .catReceita }
                    Divisor()
                    LinhaConfig(titulo: "Carteiras", valor: "\(carteiras.count) ativas") { folha = .carteiras }
                    Divisor()
                    LinhaConfig(titulo: "Receitas fixas (salário)") { folha = .fixas }
                    Divisor()
                    LinhaConfig(titulo: "Moeda padrão", valor: "\(moeda) · \(Moeda.atual.simbolo)") { folha = .moeda }
                }

                SecaoOrcamentoDia()

                Secao("Notificações") {
                    LinhaToggle(titulo: "Contas próximas do vencimento", ligado: $avisoContas)
                    if avisoContas {
                        DiasAvisoEditor { Notificacoes.reagendar(ctx) }
                            .padding(.bottom, 12)
                    }
                    Divisor()
                    LinhaToggle(titulo: "Lembrete da noite", sub: "Mostra o que você registrou no dia e pergunta se faltou algo", ligado: $lembreteRegistro)
                    if lembreteRegistro {
                        Stepper(value: $horaLembrete, in: 6...23) {
                            Text("Horário: \(horaLembrete)h").font(.system(size: 15))
                        }
                        .padding(.bottom, 10)
                    }
                    Divisor()
                    LinhaToggle(titulo: "Resumo da semana", ligado: $resumoSemana)
                    Divisor()
                    LinhaToggle(titulo: "Alertas inteligentes", ligado: $alertas)
                }

    }

    @ViewBuilder
    private var secoesSistema: some View {
        SecaoBackup()
                Secao("Segurança") {
                    LinhaToggle(titulo: "Bloqueio com Face ID", ligado: $faceID)
                }

                Secao("Automação") {
                    LinhaConfig(titulo: "Toque duplo nas costas", icone: "hand.tap") { folha = .toqueDuplo }
                    Divisor()
                    LinhaConfig(titulo: "Registrar pela maquininha", icone: "wave.3.right") { folha = .maquininha }
                    Divisor()
                    LinhaConfig(titulo: "Pix pelo e-mail ou SMS do banco", icone: "envelope") { folha = .pix }
                    Divisor()
                    LinhaConfig(titulo: "Widget \"Quanto posso gastar\"", icone: "square.grid.2x2") { folha = .widget }
                }

                Secao("Dados") {
                    LinhaConfig(titulo: "Substituir contas por uma lista", icone: "list.bullet.rectangle") { folha = .lista }
                    Divisor()
                    LinhaConfig(titulo: "Relatório do mês (PDF)", icone: "doc.richtext") {
                        if let url = RelatorioPDF.gerar(mes: Mes.indice(), ctx: ctx) { exportar = ArquivoExportado(url: url) }
                    }
                    Divisor()
                    LinhaConfig(titulo: "Exportar pro Excel (CSV)", icone: "square.and.arrow.up") {
                        if let url = CSV.gerar(transacoes) { exportar = ArquivoExportado(url: url) }
                    }
                    Divisor()
                    LinhaConfig(titulo: "Importar transações (CSV)", icone: "square.and.arrow.down") { importar = true }
                }

                Secao("Sobre") {
                    LinhaConfig(titulo: "Versão do app", valor: versao, seta: false) {}
                }

                Secao("Conta") {
                    if !email.isEmpty {
                        LinhaConfig(titulo: email, seta: false) {}
                        Divisor()
                    }
                    LinhaConfig(titulo: "Sair", icone: "rectangle.portrait.and.arrow.right", perigo: true) { confirmarSair = true }
                }

    }

    private var versao: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0"
    }
}

/// Etiquetas "1 dia ✕  3 dias ✕  +" com os avisos antes do vencimento
struct DiasAvisoEditor: View {
    var mudou: () -> Void
    @State private var dias: [Int] = Notificacoes.diasAviso()
    @State private var pedindo = false
    @State private var texto = ""
    private let opcoes = [1, 2, 3, 5, 7, 10, 15, 30]

    private func nome(_ d: Int) -> String { d == 1 ? "1 dia" : "\(d) dias" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(dias.isEmpty ? "Só no dia do vencimento. Toque em + pra avisar antes." : "Avisar antes do vencimento (e no dia):")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(dias, id: \.self) { d in
                        HStack(spacing: 6) {
                            Text(nome(d)).font(.system(size: 14, weight: .semibold))
                            Button {
                                atualizar(dias.filter { $0 != d })
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, 8)
                        .frame(height: 34)
                        .background(Color.cartao2, in: Capsule())
                    }
                    let restantes = opcoes.filter { !dias.contains($0) }
                    Menu {
                        ForEach(restantes, id: \.self) { d in
                            Button(nome(d) + " antes") { atualizar(dias + [d]) }
                        }
                        Divider()
                        Button {
                            pedindo = true
                        } label: {
                            Label("Outro número de dias...", systemImage: "pencil")
                        }
                    } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.sobreDestaque)
                                .frame(width: 34, height: 34)
                                .background(Color.destaque, in: Circle())
                    }
                }
            }
        }
        .alert("Quantos dias antes?", isPresented: $pedindo) {
            TextField("Ex.: 60", text: $texto)
                .keyboardType(.numberPad)
            Button("Adicionar") {
                if let n = Int(texto.trimmingCharacters(in: .whitespaces)), n > 0, n <= 365 {
                    atualizar(dias + [n])
                }
                texto = ""
            }
            Button("Cancelar", role: .cancel) { texto = "" }
        } message: {
            Text("Você recebe um aviso esse número de dias antes de cada vencimento (até 365).")
        }
    }

    private func atualizar(_ novos: [Int]) {
        dias = Array(Set(novos)).sorted()
        Notificacoes.salvarDiasAviso(dias)
        mudou()
    }
}

/// Backup na nuvem: último envio, "fazer agora" e "restaurar"
struct SecaoBackup: View {
    @Environment(\.modelContext) private var ctx
    @State private var trabalhando = false
    @State private var confirmar = false
    @State private var aviso: String?
    @State private var versao = 0

    private var textoUltimo: String {
        guard let d = Backup.ultimo else { return "Ainda não feito" }
        return d.formatted(.dateTime.day().month(.abbreviated).hour().minute(.twoDigits).locale(ptBR))
    }

    var body: some View {
        let _ = versao
        let erro = UserDefaults.standard.string(forKey: "erroBackup")
        Secao("Backup na nuvem") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Último backup").font(.system(size: 15))
                    Text(textoUltimo).font(.system(size: 12)).foregroundStyle(.secondary)
                    if let erro {
                        Text(erro).font(.system(size: 12)).foregroundStyle(.red)
                    }
                }
                Spacer()
                if trabalhando { ProgressView() }
            }
            .padding(.vertical, 12)
            Divisor()
            LinhaConfig(titulo: "Fazer backup agora", icone: "icloud.and.arrow.up") { fazer() }
            Divisor()
            LinhaConfig(titulo: "Restaurar do backup", icone: "icloud.and.arrow.down") { confirmar = true }
        }
        .confirmationDialog("Restaurar do backup?", isPresented: $confirmar, titleVisibility: .visible) {
            Button("Restaurar", role: .destructive) { restaurar() }
        } message: {
            Text("Troca os dados deste iPhone pelos que estão salvos na nuvem.")
        }
        .alert(aviso ?? "", isPresented: Binding(get: { aviso != nil }, set: { if !$0 { aviso = nil } })) {
            Button("OK") { aviso = nil }
        }
    }

    private func fazer() {
        trabalhando = true
        Task {
            let erro = await Backup.enviar(ctx, forcar: true)
            trabalhando = false
            versao += 1
            aviso = erro ?? "Backup feito. Seus dados estão guardados na nuvem."
        }
    }

    private func restaurar() {
        trabalhando = true
        Task {
            do {
                if let linha = try await Backup.baixar() {
                    Backup.aplicar(linha.dados, ctx: ctx)
                    aviso = "Pronto: \(linha.dados.transacoes.count) transações e \(linha.dados.contas.count) contas restauradas."
                } else {
                    aviso = "Nenhum backup encontrado nessa conta."
                }
            } catch {
                aviso = Sessao.mensagem(error)
            }
            trabalhando = false
            versao += 1
        }
    }
}

struct ArquivoExportado: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Peças da tela de Config

struct Secao<Conteudo: View>: View {
    let titulo: String
    @ViewBuilder var conteudo: () -> Conteudo

    init(_ titulo: String, @ViewBuilder conteudo: @escaping () -> Conteudo) {
        self.titulo = titulo
        self.conteudo = conteudo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(titulo.uppercased())
                .font(.system(size: 14, weight: .semibold)).tracking(1.5)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
            VStack(spacing: 0) { conteudo() }
                .padding(.horizontal, 22)
                .padding(.vertical, 4)
                .background(Color.cartao, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.borda))
        }
        .padding(.top, 26)
    }
}

struct Divisor: View {
    var body: some View { Divider().overlay(Color.borda) }
}

struct LinhaConfig: View {
    let titulo: String
    var valor: String? = nil
    var icone: String? = nil
    var perigo = false
    var seta = true
    var acao: () -> Void

    var body: some View {
        Button(action: acao) {
            HStack(spacing: 10) {
                Text(titulo)
                    .font(.system(size: 14))
                    .foregroundStyle(perigo ? Color.red : Color.primary)
                    .lineLimit(1)
                Spacer()
                if let valor { Text(valor).foregroundStyle(.secondary) }
                if let icone {
                    Image(systemName: icone).foregroundStyle(perigo ? Color.red : Color.secondary)
                } else if seta {
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Folhas

struct NomeSheet: View {
    @Binding var nome: String
    @Environment(\.dismiss) private var dismiss
    @State private var texto = ""
    @FocusState private var foco: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Seu nome").font(.system(size: 19, weight: .bold))
            Text("Como você quer ser chamado no app").foregroundStyle(.secondary)
            TextField("Seu nome", text: $texto)
                .font(.system(size: 21, weight: .bold))
                .textContentType(.name)
                .focused($foco)
                .padding(.vertical, 22)
                .padding(.horizontal, 12)
            Button("Salvar") {
                nome = texto.trimmingCharacters(in: .whitespaces)
                dismiss()
            }
            .buttonStyle(EstiloPrincipal())
        }
        .padding(28)
        .folha([.height(330)])
        .onAppear {
            texto = nome
            foco = true
        }
    }
}

struct TemaSheet: View {
    @Binding var tema: String
    @Environment(\.dismiss) private var dismiss
    private let opcoes: [(String, String, String)] = [
        ("sistema", "Sistema", "circle.lefthalf.filled"),
        ("claro", "Claro", "sun.max"),
        ("escuro", "Escuro", "moon.fill")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Aparência").font(.system(size: 19, weight: .bold)).padding(.bottom, 12)
            ForEach(opcoes.indices, id: \.self) { i in
                let o = opcoes[i]
                Button {
                    tema = o.0
                    dismiss()
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: o.2).frame(width: 26)
                        Text(o.1).font(.system(size: 15))
                        Spacer()
                        if tema == o.0 { Image(systemName: "checkmark") }
                    }
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divisor()
            }
        }
        .padding(28)
        .folha([.height(320)])
    }
}

struct MoedaSheet: View {
    @Binding var moeda: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Moeda padrão").font(.system(size: 19, weight: .bold)).padding(.bottom, 12)
                ForEach(Moeda.allCases) { m in
                    Button {
                        moeda = m.rawValue
                        dismiss()
                    } label: {
                        HStack(spacing: 16) {
                            Text(m.simbolo).font(.system(size: 15, weight: .bold)).frame(width: 60, alignment: .leading)
                            Text(m.nome).font(.system(size: 15))
                            Spacer()
                            if moeda == m.rawValue {
                                Image(systemName: "checkmark")
                            } else {
                                Text(m.rawValue).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divisor()
                }
            }
            .padding(28)
        }
        .folha([.medium, .large])
    }
}

struct CategoriasSheet: View {
    let tipo: TipoTransacao
    @Environment(\.modelContext) private var ctx
    @Query(sort: \Categoria.ordem) private var categorias: [Categoria]
    @State private var nova = ""

    private var lista: [Categoria] { categorias.filter { $0.tipo == tipo } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(tipo == .gasto ? "Categorias de gasto" : "Categorias de receita")
                    .font(.system(size: 19, weight: .bold))
                    .padding(.bottom, 16)
                HStack(spacing: 12) {
                    TextField("Nova categoria...", text: $nova)
                        .submitLabel(.done)
                        .onSubmit(adicionar)
                        .campo()
                    Button(action: adicionar) {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.sobreDestaque)
                            .frame(width: 60, height: 58)
                            .background(Color.destaque, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 12)

                ForEach(lista) { c in
                    HStack(spacing: 14) {
                        Image(systemName: c.icone).frame(width: 24).foregroundStyle(.secondary)
                        Text(c.nome).font(.system(size: 15))
                        Spacer()
                        if tipo == .gasto {
                            Button(c.essencial ? "essencial" : "desejo") {
                                c.essencial.toggle()
                                try? ctx.save()
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plain)
                        }
                        Button {
                            ctx.delete(c)
                            try? ctx.save()
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 16)
                    Divisor()
                }
                if tipo == .gasto {
                    Text("Toque em essencial/desejo pra mudar. Isso aparece na Análise.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 12)
                }
            }
            .padding(28)
        }
        .folha([.large])
    }

    private func adicionar() {
        let n = nova.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !lista.contains(where: { $0.nome.lowercased() == n.lowercased() }) else { return }
        ctx.insert(Categoria(nome: n, icone: Categoria.iconePadrao(n), tipo: tipo,
                             essencial: true, ordem: (lista.map(\.ordem).max() ?? 0) + 1))
        try? ctx.save()
        nova = ""
    }
}

struct CarteirasSheet: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \Carteira.ordem) private var carteiras: [Carteira]
    @State private var frente: UUID?
    @State private var removendo: Carteira?
    @State private var adicionando = false
    @State private var editandoCarteira: Carteira?

    var body: some View {
        let principal = carteiras.first { $0.chave == frente } ?? carteiras.first
        let resto = carteiras.filter { $0.chave != principal?.chave }

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Carteiras").font(.system(size: 21, weight: .bold)).padding(.bottom, 20)
                if let principal {
                    CartaoCarteira(carteira: principal, aberto: true)
                        .onTapGesture { editandoCarteira = principal }
                        .onLongPressGesture { removendo = principal }
                }
                VStack(spacing: -22) {
                    ForEach(resto) { c in
                        CartaoCarteira(carteira: c, aberto: false)
                            .onTapGesture { withAnimation(.snappy) { frente = c.chave } }
                            .onLongPressGesture { removendo = c }
                    }
                }
                .padding(.top, 14)
                Text("toque num cartão pra trazer pra frente · toque no da frente pra editar (fechamento e vencimento) · segure pra remover")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 34)
                Button("Adicionar meio de pagamento") { adicionando = true }
                    .buttonStyle(EstiloPrincipal())
                    .padding(.top, 20)
            }
            .padding(28)
        }
        .folha([.large])
        .sheet(isPresented: $adicionando) { NovaCarteiraSheet(ordem: (carteiras.map(\.ordem).max() ?? 0) + 1) }
        .sheet(item: $editandoCarteira) { c in NovaCarteiraSheet(ordem: c.ordem, carteira: c) }
        .confirmationDialog("Remover \(removendo?.nome ?? "")?",
                            isPresented: Binding(get: { removendo != nil }, set: { if !$0 { removendo = nil } }),
                            titleVisibility: .visible) {
            Button("Remover", role: .destructive) {
                if let removendo { ctx.delete(removendo) }
                try? ctx.save()
                removendo = nil
            }
        } message: {
            Text("As transações já registradas continuam com o nome dela.")
        }
    }
}

struct CartaoCarteira: View {
    let carteira: Carteira
    let aberto: Bool

    var body: some View {
        VStack(alignment: .leading) {
            HStack(spacing: 14) {
                Image(systemName: carteira.tipo.icone).font(.system(size: 17, weight: .semibold))
                Text(carteira.nome).font(.system(size: 17, weight: .bold)).lineLimit(1)
                Spacer()
            }
            if aberto {
                Spacer()
                HStack {
                    Text(carteira.tipo.nome.uppercased()).tracking(2)
                    Spacer()
                    if carteira.tipo == .credito {
                        Text(carteira.diaFechamento > 0
                             ? "fecha dia \(carteira.diaFechamento) · vence dia \(carteira.diaVencimento)"
                             : "vence dia \(carteira.diaVencimento) · toque pra pôr o fechamento")
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: aberto ? 200 : 80, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.16)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RadialGradient(colors: [.white.opacity(0.25), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                )
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.35), radius: 10, y: -2)
        }
    }
}

struct NovaCarteiraSheet: View {
    let ordem: Int
    /// Preenchido quando é pra editar um cartão/carteira existente
    var carteira: Carteira? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx
    @Query private var transacoes: [Transacao]
    @Query private var contas: [Conta]
    @State private var nome = ""
    @State private var tipo: TipoCarteira = .credito
    @State private var vencimentoTexto = ""
    @State private var fechamentoTexto = ""

    private var nomeLimpo: String { nome.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(carteira == nil ? "Novo meio de pagamento" : "Editar \(carteira?.nome ?? "")")
                    .font(.system(size: 19, weight: .bold))
                TextField("Nome (ex.: Nubank, Inter)", text: $nome).campo()
                Picker("Tipo", selection: $tipo) {
                    ForEach(TipoCarteira.allCases) { t in Text(t.nome).tag(t) }
                }
                .pickerStyle(.segmented)
                if tipo == .credito {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Fatura fecha dia").font(.system(size: 13)).foregroundStyle(.secondary)
                            TextField("ex: 26", text: $fechamentoTexto).keyboardType(.numberPad).campo()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Vence dia").font(.system(size: 13)).foregroundStyle(.secondary)
                            TextField("ex: 2", text: $vencimentoTexto).keyboardType(.numberPad).campo()
                        }
                    }
                    Text(explicacao)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Button("Salvar") { salvar() }
                    .buttonStyle(EstiloPrincipal(ativo: !nomeLimpo.isEmpty))
                    .disabled(nomeLimpo.isEmpty)
                    .padding(.top, 6)
            }
            .padding(28)
        }
        .folha([.large])
        .onAppear {
            guard let c = carteira else { return }
            nome = c.nome
            tipo = c.tipo
            vencimentoTexto = String(c.diaVencimento)
            fechamentoTexto = c.diaFechamento > 0 ? String(c.diaFechamento) : ""
        }
    }

    private var explicacao: String {
        guard let f = Int(fechamentoTexto), (1...31).contains(f) else {
            return "Com o dia de fechamento, cada compra no crédito entra sozinha na fatura certa e só sai do saldo no mês em que a fatura vence. Sem ele, a compra sai do saldo no dia."
        }
        let v = min(max(Int(vencimentoTexto) ?? 10, 1), 31)
        let proximo = v <= f ? "do mês seguinte" : "do mesmo mês"
        return "Compras até o dia \(f - 1) entram na fatura que fecha dia \(f) e vence dia \(v) \(proximo). A partir do dia \(f), vão pra fatura seguinte."
    }

    private func salvar() {
        let venc = min(max(Int(vencimentoTexto) ?? 10, 1), 31)
        let fecha = tipo == .credito ? min(max(Int(fechamentoTexto) ?? 0, 0), 31) : 0
        if let c = carteira {
            let antigo = c.nome
            if antigo != nomeLimpo {
                // leva o nome novo pras transações e pagamentos que usavam o antigo
                for t in transacoes where t.carteira == antigo { t.carteira = nomeLimpo }
                for conta in contas {
                    conta.pagamentos = conta.pagamentos.map {
                        var e = $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                        if e.count > 1 && e[1] == antigo { e[1] = nomeLimpo }
                        return e.joined(separator: "|")
                    }
                }
            }
            c.nome = nomeLimpo
            c.tipoRaw = tipo.rawValue
            c.diaVencimento = venc
            c.diaFechamento = fecha
        } else {
            let nova = Carteira(nome: nomeLimpo, tipo: tipo, diaVencimento: venc, ordem: ordem)
            nova.diaFechamento = fecha
            ctx.insert(nova)
        }
        try? ctx.save()
        Notificacoes.reagendar(ctx)
        dismiss()
    }
}

// MARK: - Guias de automação

struct GuiaView: View {
    enum Guia { case toqueDuplo, maquininha, pix, widget }
    let guia: Guia
    @Environment(\.dismiss) private var dismiss

    private var titulo: String {
        switch guia {
        case .toqueDuplo: return "Toque duplo nas costas"
        case .maquininha: return "Registrar pela maquininha"
        case .pix: return "Pix pelo e-mail ou SMS"
        case .widget: return "Widget \"Quanto posso gastar\""
        }
    }
    private var passos: [String] {
        switch guia {
        case .toqueDuplo:
            return [
                "Abra o app Atalhos e toque em + pra criar um atalho novo.",
                "Toque em \"Adicionar Ação\", procure \"Novo registro\" (LBO Finanças) e adicione.",
                "Dê o nome \"Registrar gasto\" pro atalho e salve.",
                "Agora abra Ajustes → Acessibilidade → Toque → Tocar Atrás.",
                "Escolha \"Toque Duplo\" e selecione o atalho \"Registrar gasto\".",
                "Pronto: dois toques nas costas do iPhone abrem a tela de registrar na hora."
            ]
        case .pix:
            return [
                "No app do seu banco, ative o aviso por e-mail (ou SMS) de Pix enviado e recebido.",
                "Abra o app Atalhos → Automação → + e escolha \"E-mail\" (ou \"Mensagem\", se o banco avisa por SMS).",
                "Em Remetente, escolha o e-mail (ou número) do banco. Se quiser, em Assunto/Mensagem contém, escreva \"Pix\".",
                "Marque \"Executar Imediatamente\" e toque em Seguinte → Nova Automação em Branco.",
                "Adicione a ação \"Registrar por texto\" do LBO Finanças.",
                "Em Texto, escolha Entrada do Atalho, toque nela e selecione \"Conteúdo\" (o corpo do e-mail ou da mensagem).",
                "Salve. Cada Pix enviado vira gasto e cada Pix recebido vira receita, com o nome da pessoa e o valor.",
                "Se o mesmo valor já foi registrado nos últimos 30 minutos (ex.: e-mail e SMS do mesmo Pix), o app ignora pra não duplicar.",
                "Não reconheceu direito? Mande um exemplo do texto do seu banco que dá pra ajustar.",
                "Banco que não manda e-mail (ex.: Nubank)? Use o comprovante: no app Atalhos, crie um atalho novo chamado \"Registrar comprovante\".",
                "Toque no (i) do atalho e ligue \"Mostrar ao Compartilhar\"; em Tipos, deixe só Imagens e PDFs.",
                "Adicione só a ação \"Registrar comprovante\" do LBO Finanças, com Comprovante = Entrada do Atalho. Ela lê PDF e imagem sozinha.",
                "Depois de um Pix, toque em Compartilhar comprovante → Registrar comprovante. Pronto."
            ]
        case .widget:
            return [
                "Abra o app Atalhos e toque em + pra criar um atalho novo.",
                "Toque em \"Adicionar Ação\", procure \"Quanto posso gastar hoje\" (LBO Finanças) e adicione.",
                "Dê o nome \"Quanto posso gastar\" e salve.",
                "Na tela inicial do iPhone, toque e segure num espaço vazio até os ícones tremerem.",
                "Toque em Editar (canto de cima) → Adicionar Widget, procure \"Atalhos\" e escolha o tamanho pequeno.",
                "Toque no widget novo e, em Atalho, escolha \"Quanto posso gastar\".",
                "Pronto: um toque no widget mostra quanto ainda dá pra gastar hoje, o orçamento da semana e o saldo, sem abrir o app.",
                "Também funciona pela Siri: \"E aí Siri, quanto posso gastar no LBO Finanças\"."
            ]
        case .maquininha:
            return [
                "Abra este app pelo menos uma vez, pra o iPhone conhecer a ação \"Registrar gasto\".",
                "Abra o app Atalhos e vá em Automação.",
                "Toque em + e escolha \"Transação\".",
                "Selecione seus cartões da Carteira, marque \"Executar Imediatamente\" e avance.",
                "Adicione a ação \"Registrar gasto\" do LBO Finanças e toque na seta pra ver todos os campos.",
                "Valor: escolha a variável \"Quantia\" da transação.",
                "Onde foi?: escolha a variável \"Comerciante\".",
                "Cartão: escolha a variável \"Cartão\".",
                "Deixe Categoria e Pagamento em branco: o app escolhe sozinho pelo nome do lugar e pelo cartão.",
                "Salve. Na próxima compra por aproximação, o gasto entra sozinho, sem abrir nenhuma pergunta.",
                "Categoria errada? Toque na transação e corrija uma vez: das próximas vezes, o app lembra."
            ]
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(titulo).font(.system(size: 21, weight: .bold))
                    Spacer()
                    BotaoFechar { dismiss() }
                }
                ForEach(passos.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(i + 1)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.sobreDestaque)
                            .frame(width: 28, height: 28)
                            .background(Color.destaque, in: Circle())
                        Text(passos[i]).font(.system(size: 14))
                    }
                }
                if guia == .pix { ultimoTexto }
            }
            .padding(28)
        }
        .folha([.large])
    }

    /// O último texto que chegou pelo "Registrar por texto"/"Registrar comprovante", pra conferir e mandar pro suporte
    @ViewBuilder
    private var ultimoTexto: some View {
        let texto = UserDefaults.standard.string(forKey: "ultimoTextoLido") ?? ""
        let data = UserDefaults.standard.object(forKey: "ultimoTextoData") as? Date
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ÚLTIMO TEXTO LIDO").font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                if !texto.isEmpty {
                    Button("Copiar") { UIPasteboard.general.string = texto }
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            if let data {
                Text(data.formatted(.dateTime.day().month().hour().minute().locale(ptBR)))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(texto.isEmpty ? "Nada recebido ainda." : texto)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(25)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cartao2.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 10)
    }
}
