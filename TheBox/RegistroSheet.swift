import SwiftUI
import SwiftData

/// Tela de registrar (botão +, toque duplo nas costas ou tocando numa transação pra editar)
struct RegistroSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx
    @Query(sort: \Categoria.ordem) private var categorias: [Categoria]
    @Query(sort: \Carteira.ordem) private var carteiras: [Carteira]
    @Query private var transacoes: [Transacao]
    @Query private var contas: [Conta]
    @Query(sort: \Caixinha.ordem) private var caixinhas: [Caixinha]
    @Query private var limites: [LimiteMensal]
    @State private var avisoEstouro = false

    let editando: Transacao?
    @State private var tipo: TipoTransacao
    @State private var digitos: String
    @State private var categoria: String?
    @State private var carteira: String?
    @State private var descricao: String
    @State private var data: Date
    @State private var mostrarData = false
    @State private var confirmarExclusao = false
    @State private var entrada: Bool
    @State private var repetirReceita = false
    @State private var foto: Data?
    @State private var destino: String
    @FocusState private var focoValor: Bool
    @FocusState private var focoDescricao: Bool

    init(editando: Transacao? = nil) {
        self.editando = editando
        _tipo = State(initialValue: editando?.tipo ?? .gasto)
        _digitos = State(initialValue: editando.map { String(Int(($0.valor * 100).rounded())) } ?? "")
        _categoria = State(initialValue: editando?.categoria)
        _carteira = State(initialValue: editando?.carteira)
        _descricao = State(initialValue: editando?.descricao ?? "")
        _data = State(initialValue: editando?.data ?? .now)
        _entrada = State(initialValue: editando?.entrada ?? false)
        _foto = State(initialValue: editando?.foto)
        _destino = State(initialValue: editando?.destino ?? "")
    }

    private var valor: Double { Double(Int(digitos) ?? 0) / 100 }
    private var cats: [Categoria] { categorias.filter { $0.tipo == tipo } }
    /// Destinos de uma transferência: caixinhas, outra conta sua e (se saiu) pagamento de fatura
    private var destinos: [String] {
        caixinhas.map { Transacao.prefixoCaixinha + $0.nome } + [Transacao.outraConta]
            + (entrada ? [] : [Transacao.pagamentoFatura])
    }
    private var opcoesAtuais: [String] { tipo == .transferencia ? destinos : cats.map(\.nome) }
    private var valido: Bool { valor > 0 && categoria != nil }

    /// Quanto esse gasto passa do orçamento do dia/semana (ou do mês, se não tiver um do dia a dia)
    private var estouro: (excesso: Double, nome: String)? {
        guard tipo == .gasto, valor > 0, categoria != Transacao.categoriaAjuste else { return nil }
        let outras = transacoes.filter { $0.chave != editando?.chave }
        if let s = OrcamentoDia.situacao(em: data, transacoes: outras) {
            let excesso = s.gasto + valor - s.limite
            return excesso > 0.009 ? (excesso, s.nome) : nil
        }
        let fin = Financas(transacoes: outras, contas: contas, carteiras: carteiras, limites: limites)
        let m = Mes.indice(data)
        let lim = fin.limite(em: m)
        guard lim > 0 else { return nil }
        let excesso = fin.gastoTotal(em: m) + valor - lim
        return excesso > 0.009 ? (excesso, "do mês") : nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    topo
                    if mostrarData {
                        DatePicker("Data", selection: $data, displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                    }
                    SeletorTipo(tipo: $tipo)
                    campoValor
                    if tipo == .transferencia {
                        gradeDestinos
                    } else {
                        gradeCategorias
                    }
                    if tipo == .gasto { impacto }
                    if let e = estouro {
                        Label("Isso passa do seu orçamento \(e.nome) em \(e.excesso.moeda).", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    if tipo != .transferencia { pagamentos } else { bancosTransferencia }
                    if tipo == .receita && editando == nil {
                        LinhaToggle(titulo: "Repete todo mês",
                                    sub: "Ex.: salário. Entra sozinha todo dia \(Calendar.current.component(.day, from: data)) nos próximos meses",
                                    ligado: $repetirReceita)
                    }
                    TextField(tipo == .gasto ? "Onde foi? (opcional)" : (tipo == .receita ? "De onde veio? (opcional)" : "Descrição (opcional)"),
                              text: $descricao)
                        .focused($focoDescricao)
                        .submitLabel(.done)
                        .campo()
                    CampoFoto(foto: $foto)
                    Button(editando == nil ? "Registrar" : "Salvar") {
                        if editando == nil && estouro != nil { avisoEstouro = true } else { salvar() }
                    }
                        .buttonStyle(EstiloPrincipal(ativo: valido))
                        .disabled(!valido)
                    if editando != nil {
                        Button("Excluir", role: .destructive) { confirmarExclusao = true }
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.cartao)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("OK") {
                        focoValor = false
                        focoDescricao = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .folha()
        .onChange(of: tipo) { _, _ in
            if !opcoesAtuais.contains(where: { $0 == categoria }) { categoria = nil }
        }
        .onChange(of: entrada) { _, _ in
            if !opcoesAtuais.contains(where: { $0 == categoria }) { categoria = nil }
        }
        .onChange(of: digitos) { _, novo in
            let limpo = String(novo.filter(\.isNumber).prefix(9))
            if limpo != novo { digitos = limpo }
        }
        .onAppear {
            if carteira == nil { carteira = carteiras.first?.nome }
            if editando == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focoValor = true }
            }
        }
        .confirmationDialog("Passa do orçamento \(estouro?.nome ?? "") em \(estouro?.excesso.moeda ?? "")",
                            isPresented: $avisoEstouro, titleVisibility: .visible) {
            Button("Registrar mesmo assim") { salvar() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Vale a pena? Se não for essencial, dá pra deixar pra depois.")
        }
        .confirmationDialog("Excluir esta transação?", isPresented: $confirmarExclusao, titleVisibility: .visible) {
            Button("Excluir", role: .destructive) {
                if let editando { Exclusao.transacao(editando, ctx: ctx) }
                dismiss()
            }
        }
    }

    // MARK: Partes

    private var topo: some View {
        HStack {
            Button {
                withAnimation { mostrarData.toggle() }
            } label: {
                Label(textoData, systemImage: "calendar")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(Color.cartao2.opacity(0.6), in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
            BotaoFechar { dismiss() }
        }
    }

    private var textoData: String {
        let cal = Calendar.current
        let hora = data.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(ptBR))
        if cal.isDateInToday(data) { return "Hoje · \(hora)" }
        if cal.isDateInYesterday(data) { return "Ontem · \(hora)" }
        if cal.isDateInTomorrow(data) { return "Amanhã · \(hora)" }
        return data.formatted(.dateTime.day().month(.abbreviated).locale(ptBR)) + " · " + hora
    }

    private var campoValor: some View {
        VStack(spacing: 2) {
            Text(Moeda.atual.simbolo).font(.system(size: 14)).foregroundStyle(.secondary)
            ZStack {
                TextField("", text: $digitos)
                    .keyboardType(.numberPad)
                    .focused($focoValor)
                    .opacity(0.02)
                    .frame(width: 2, height: 2)
                Text(valor.formatted(.number.precision(.fractionLength(2)).locale(ptBR)))
                    .font(.system(size: 52, weight: .heavy)).tracking(-2.5)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .foregroundStyle(valor > 0 ? Color.primary : Color.secondary.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { focoValor = true }
    }

    private var gradeCategorias: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(cats) { c in
                ChipOpcao(texto: c.nome, icone: c.icone, selecionado: categoria == c.nome) {
                    categoria = c.nome
                    focoValor = false
                }
            }
        }
    }

    private var gradeDestinos: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Sentido", selection: $entrada) {
                Text("Saiu da conta").tag(false)
                Text("Entrou na conta").tag(true)
            }
            .pickerStyle(.segmented)
            Text(entrada ? "De onde veio?" : "Pra onde foi?")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(destinos, id: \.self) { d in
                    ChipOpcao(texto: d.hasPrefix(Transacao.prefixoCaixinha) ? String(d.dropFirst(Transacao.prefixoCaixinha.count)) : d,
                              icone: d.hasPrefix(Transacao.prefixoCaixinha) ? "shippingbox.fill"
                                : (d == Transacao.outraConta ? "building.columns" : "creditcard"),
                              selecionado: categoria == d) {
                        categoria = d
                        focoValor = false
                    }
                }
            }
            Text(caixinhas.isEmpty
                 ? "Transferência não é gasto nem receita: só mexe no saldo da conta. Crie caixinhas na aba Quitar."
                 : "Transferência não é gasto nem receita: só mexe no saldo da conta.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var impacto: some View {
        if let nome = categoria, let cat = cats.first(where: { $0.nome == nome }), cat.limite > 0, valor > 0 {
            let fin = Financas(transacoes: transacoes, contas: contas, carteiras: carteiras)
            let anterior = editando?.categoria == nome ? (editando?.valor ?? 0) : 0
            let ja = (fin.gastoPorCategoria(em: Mes.indice(data))[nome] ?? 0) - anterior
            let p = (ja + valor) / cat.limite
            VStack(alignment: .leading, spacing: 8) {
                BarraProgresso(p: p, cor: corPorcentagem(p), altura: 4)
                Text("Isso deixa \(nome) em \(porcento(p)) do orçamento do mês.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// De qual banco saiu (ou entrou) e, entre bancos seus, pra qual foi
    private var bancosTransferencia: some View {
        let bancos = carteiras.filter { $0.tipo != .credito }
        return VStack(alignment: .leading, spacing: 10) {
            Text(entrada ? "Em qual banco entrou?" : "De qual banco saiu?")
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(bancos) { c in
                        ChipOpcao(texto: c.nome, icone: c.tipo.icone, selecionado: carteira == c.nome, cheio: false) {
                            carteira = c.nome
                            if destino == c.nome { destino = "" }
                        }
                    }
                }
            }
            if categoria == Transacao.outraConta && !entrada {
                Text("Pra qual banco seu foi?").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(bancos.filter { $0.nome != carteira }) { c in
                            ChipOpcao(texto: c.nome, icone: c.tipo.icone, selecionado: destino == c.nome, cheio: false) {
                                destino = c.nome
                            }
                        }
                    }
                }
                Text("Dinheiro que só trocou de banco: o total não muda, só o saldo de cada banco.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if !bancos.contains(where: { $0.nome == carteira }) { carteira = bancos.first?.nome }
        }
    }

    private var pagamentos: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tipo == .gasto ? "Como você pagou?" : "Onde entrou?")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(carteiras) { c in
                        ChipOpcao(texto: c.nome, icone: c.tipo.icone, selecionado: carteira == c.nome, cheio: false) {
                            carteira = c.nome
                        }
                    }
                }
            }
            if tipo == .gasto, let c = carteiras.first(where: { $0.nome == carteira }), c.usaFatura {
                let m = c.mesVencimento(da: data)
                Label("Entra na fatura de \(Mes.nome(m).lowercased()) (vence dia \(c.diaVencimento)) e só sai do saldo nesse mês.",
                      systemImage: "creditcard")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func salvar() {
        guard valido, let categoria else { return }
        let desc = descricao.trimmingCharacters(in: .whitespaces)
        let cart = carteira ?? ""
        if let t = editando {
            t.tipoRaw = tipo.rawValue
            t.valor = valor
            t.categoria = categoria
            t.carteira = cart
            t.descricao = desc
            t.data = data
            t.entrada = tipo == .transferencia ? entrada : false
            t.destino = tipo == .transferencia && categoria == Transacao.outraConta && !entrada ? destino : ""
            t.foto = foto
            try? ctx.save()
        } else {
            let nova = Transacao(tipo: tipo, valor: valor, categoria: categoria, carteira: cart,
                                 descricao: desc, data: data, entrada: tipo == .transferencia ? entrada : false)
            nova.destino = tipo == .transferencia && categoria == Transacao.outraConta && !entrada ? destino : ""
            nova.foto = foto
            ctx.insert(nova)
            if tipo == .receita && repetirReceita {
                ctx.insert(Recorrencia(nome: desc.isEmpty ? categoria : desc, valor: valor,
                                       dia: Calendar.current.component(.day, from: data),
                                       categoria: categoria, carteira: cart, ultimoMes: Mes.indice(data)))
            }
            try? ctx.save()
            Notificacoes.registrado(valor: valor, titulo: desc.isEmpty ? tipo.nome : desc, categoria: categoria)
            if tipo == .gasto {
                Notificacoes.verificarLimite(categoria: categoria, valor: valor, data: data, ctx: ctx)
            }
        }
        Notificacoes.reagendar(ctx)
        dismiss()
    }
}

struct SeletorTipo: View {
    @Binding var tipo: TipoTransacao

    var body: some View {
        HStack(spacing: 4) {
            ForEach(TipoTransacao.allCases) { t in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { tipo = t }
                } label: {
                    Text(t.nome)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .foregroundStyle(tipo == t ? Color.sobreDestaque : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background {
                            if tipo == t {
                                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.destaque)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.cartao2.opacity(0.55), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
