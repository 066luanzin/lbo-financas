import SwiftUI
import SwiftData

struct HomeView: View {
    @Binding var mes: Int
    @Environment(\.modelContext) private var ctx
    @Environment(AppState.self) private var estado
    @Query(sort: \Transacao.data, order: .reverse) private var transacoes: [Transacao]
    @Query private var contas: [Conta]
    @Query(sort: \Carteira.ordem) private var carteiras: [Carteira]
    @Query(sort: \Categoria.ordem) private var categorias: [Categoria]
    @Query private var limites: [LimiteMensal]
    @Query private var recorrencias: [Recorrencia]
    @AppStorage("nomeUsuario") private var nome = ""
    @AppStorage("ocultarSaldo") private var ocultar = false
    @AppStorage("orcAtivo") private var orcAtivo = false
    @AppStorage("orcModo") private var orcModo = "dia"
    @State private var detalhes = false
    @State private var todas = false
    @State private var editando: Transacao?
    @State private var diaFiltro: Date?

    private var saudacao: String {
        let h = Calendar.current.component(.hour, from: .now)
        return h < 12 ? "Bom dia" : (h < 18 ? "Boa tarde" : "Boa noite")
    }

    var body: some View {
        let fin = Financas(transacoes: transacoes, contas: contas, carteiras: carteiras, limites: limites,
                           recorrencias: recorrencias)
        // a correção pra bater com o banco não é um gasto nem uma receita de verdade: fica só em Ver detalhes
        let doMes = fin.transacoes(em: mes).filter { !$0.ehAjuste }
        let limite = fin.limite(em: mes)
        let gasto = fin.gastoTotal(em: mes)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Cabecalho(sub: saudacao, titulo: nome.isEmpty ? "Olá" : nome) {
                    SeletorMes(mes: $mes)
                    BotaoCirculo(icone: "plus") { estado.abrirRegistro = true }
                }

                CartaoSaldo(saldo: fin.saldoPrevisto(em: mes), saldoHoje: fin.saldo(em: mes),
                            aPagar: fin.contasAPagar(em: mes) + fin.faturasAPagar(em: mes),
                            mesAtual: mes == Mes.indice(),
                            progresso: limite > 0 ? gasto / limite : 0,
                            ocultar: $ocultar) { detalhes = true }

                if mes == Mes.indice() && !ocultar {
                    CartaoBancos(fin: fin) { detalhes = true }
                    if orcAtivo, let s = OrcamentoDia.situacao(em: .now, transacoes: transacoes) {
                        CartaoOrcamentoDia(limite: s.limite, gasto: s.gasto, nome: s.nome)
                    } else {
                        CartaoHoje(fin: fin, mes: mes)
                    }
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("Últimas transações").font(.system(size: 19, weight: .bold))
                    Spacer()
                    Button("Ver todas") { todas = true }
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 10)

                if doMes.isEmpty {
                    Vazio(titulo: "Nenhuma transação ainda",
                          texto: "Dê 2 toques na parte traseira do iPhone para registrar")
                } else {
                    let dias = Array(Set(doMes.map { Calendar.current.startOfDay(for: $0.data) })).sorted(by: >)
                    let lista = diaFiltro.map { d in doMes.filter { Calendar.current.isDate($0.data, inSameDayAs: d) } } ?? doMes
                    FiltroDias(dias: dias, transacoes: doMes, selecionado: $diaFiltro)
                    if let d = diaFiltro {
                        let gastosDia = lista.filter { $0.tipo == .gasto && !$0.ehAjuste }.reduce(0) { $0 + $1.valor }
                        let receitasDia = lista.filter { $0.tipo == .receita }.reduce(0) { $0 + $1.valor }
                        HStack {
                            Text(d.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(ptBR)))
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Gastou \(gastosDia.moeda)").font(.system(size: 14, weight: .bold))
                                if receitasDia > 0 {
                                    Text("Entrou \(receitasDia.moeda)").font(.system(size: 12)).foregroundStyle(.green)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    VStack(spacing: 10) {
                        ForEach(diaFiltro == nil ? Array(lista.prefix(15)) : lista) { t in
                            LinhaTransacao(transacao: t, iconeCarteira: iconeCarteira(t.carteira))
                                .onTapGesture { editando = t }
                                .deslizarParaApagar { apagar(t) }
                                .contextMenu {
                                    Button { editando = t } label: { Label("Editar", systemImage: "pencil") }
                                    Button(role: .destructive) { apagar(t) } label: { Label("Apagar", systemImage: "trash") }
                                }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(Color.fundo)
        .sheet(isPresented: $detalhes) { DetalhesSaldoView(mes: mes) }
        .sheet(isPresented: $todas) { TodasTransacoesView() }
        .sheet(item: $editando) { t in RegistroSheet(editando: t) }
        .onChange(of: mes) { _, _ in diaFiltro = nil }
    }

    private func apagar(_ t: Transacao) {
        Exclusao.transacao(t, ctx: ctx)
    }

    private func iconeCarteira(_ nome: String) -> String {
        carteiras.first { $0.nome == nome }?.tipo.icone ?? "creditcard"
    }
}

/// "Quanto posso gastar hoje": o que sobra pro dia a dia dividido pelos dias que faltam no mês
struct CartaoHoje: View {
    let fin: Financas
    let mes: Int

    var body: some View {
        let cal = Calendar.current
        let agora = Date.now
        let diasNoMes = cal.range(of: .day, in: .month, for: agora)?.count ?? 30
        let dias = max(1, diasNoMes - cal.component(.day, from: agora) + 1)
        let gastoHoje = fin.transacoes(em: mes).filter { $0.tipo == .gasto && !$0.ehAjuste && cal.isDateInToday($0.data) }
            .reduce(0) { $0 + $1.valor }
        let limite = fin.limite(em: mes)
        let temRenda = fin.receitas(em: mes) + fin.receitasAReceber(em: mes) > 0 || fin.abertura(em: mes) > 0
        let porLimite = limite - fin.gastoTotal(em: mes) - fin.contasAPagar(em: mes)
        let previsto = fin.saldoPrevisto(em: mes)
        // o que ainda dá pra gastar até o fim do mês (somando de volta o que já saiu hoje)
        // sem receita no mês o app não sabe quanto dinheiro existe: o limite sozinho não é dinheiro
        let disponivel: Double = (limite > 0 ? min(porLimite, previsto) : previsto) + gastoHoje
        let porDia = max(0, disponivel) / Double(dias)
        let restaHoje = porDia - gastoHoje
        let semBase = !temRenda

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("PODE GASTAR HOJE").font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                if !semBase {
                    Text(porDia.moeda)
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(disponivel <= 0 ? Color.red : (restaHoje < 0 ? Color.orange : Color.green))
                }
            }
            if semBase {
                Text("Nenhuma entrada registrada em \(Mes.nome(mes).lowercased()). Registre como Receita o salário ou o saldo que você já tinha na conta no começo do mês pra calcular.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            } else if disponivel <= 0 {
                Text("O mês já fechou no vermelho: evite qualquer gasto que não seja essencial.")
                    .font(.system(size: 13)).foregroundStyle(.red)
            } else {
                BarraProgresso(p: porDia > 0 ? gastoHoje / porDia : 0,
                               cor: restaHoje < 0 ? .orange : .green, altura: 4)
                HStack {
                    Text("Gastou hoje \(gastoHoje.moeda)")
                    Spacer()
                    Text(restaHoje >= 0 ? "Resta \(restaHoje.moeda)" : "Passou \(abs(restaHoje).moeda)")
                        .foregroundStyle(restaHoje >= 0 ? Color.secondary : Color.orange)
                }
                .font(.system(size: 13))
                Text("\(max(0, disponivel).moeda) pra \(dias) \(dias == 1 ? "dia" : "dias") até o fim do mês")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .cartao(18)
    }
}

/// Fileira "Todos · 29 · 28 · 27..." com o total gasto em cada dia
struct FiltroDias: View {
    let dias: [Date]
    let transacoes: [Transacao]
    @Binding var selecionado: Date?

    private func gasto(_ d: Date) -> Double {
        transacoes.filter { $0.tipo == .gasto && !$0.ehAjuste && Calendar.current.isDate($0.data, inSameDayAs: d) }
            .reduce(0) { $0 + $1.valor }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                botao(ativo: selecionado == nil) {
                    Text("Todos").font(.system(size: 14, weight: .semibold))
                } acao: { selecionado = nil }
                ForEach(dias, id: \.self) { d in
                    botao(ativo: selecionado.map { Calendar.current.isDate($0, inSameDayAs: d) } ?? false) {
                        VStack(spacing: 1) {
                            Text(d.formatted(.dateTime.weekday(.abbreviated).locale(ptBR)).lowercased())
                                .font(.system(size: 11))
                            Text(d.formatted(.dateTime.day()))
                                .font(.system(size: 17, weight: .bold))
                            Text(gasto(d).curto)
                                .font(.system(size: 10))
                        }
                    } acao: { selecionado = d }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func botao<C: View>(ativo: Bool, @ViewBuilder conteudo: () -> C, acao: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { acao() }
        } label: {
            conteudo()
                .foregroundStyle(ativo ? Color.sobreDestaque : Color.primary)
                .frame(minWidth: 52, minHeight: 60)
                .padding(.horizontal, 6)
                .background(ativo ? Color.destaque : Color.cartao,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.borda))
        }
        .buttonStyle(.plain)
    }
}

struct CartaoSaldo: View {
    /// Quanto sobra no fim do mês depois de pagar tudo
    let saldo: Double
    let saldoHoje: Double
    let aPagar: Double
    /// No mês atual o número grande é o que está na conta hoje (igual ao banco)
    var mesAtual = true
    let progresso: Double
    @Binding var ocultar: Bool
    var detalhes: () -> Void

    var body: some View {
        VStack(spacing: -20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(mesAtual ? "Na conta hoje" : "Sobra prevista no mês").font(.system(size: 15)).foregroundStyle(.secondary)
                    Spacer()
                    Button { withAnimation { ocultar.toggle() } } label: {
                        Image(systemName: ocultar ? "eye.slash" : "eye").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                let principal = mesAtual ? saldoHoje : saldo
                Text(ocultar ? "\(Moeda.atual.simbolo) ••••••" : principal.moeda)
                    .font(.system(size: 32, weight: .heavy)).tracking(-1.2)
                    .foregroundStyle(principal < 0 && !ocultar ? Color.red : Color.primary)
                    .lineLimit(1).minimumScaleFactor(0.5)
                if aPagar > 0 && !ocultar {
                    Text(mesAtual
                         ? (saldo >= 0 ? "Contas a pagar: \(aPagar.moeda) · sobra \(saldo.moeda) no fim do mês"
                                       : "Contas a pagar: \(aPagar.moeda) · faltam \(abs(saldo).moeda) pra cobrir")
                         : "Contas do mês: \(aPagar.moeda)")
                        .font(.system(size: 13))
                        .foregroundStyle(mesAtual && saldo < 0 ? Color.red : Color.secondary)
                        .lineLimit(2).minimumScaleFactor(0.8)
                }
                BarraProgresso(p: progresso, cor: corPorcentagem(progresso), altura: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
            }
            .cartao(22)

            Button(action: detalhes) {
                Text("Ver detalhes")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 22)
                    .frame(height: 40)
                    .background(Color.cartao2, in: Capsule())
                    .overlay(Capsule().stroke(Color.borda))
            }
            .buttonStyle(.plain)
        }
    }
}

struct LinhaTransacao: View {
    let transacao: Transacao
    var iconeCarteira = "creditcard"

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(transacao.titulo).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if transacao.foto != nil {
                        Image(systemName: "paperclip").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: iconeCarteira).font(.caption)
                    Text(transacao.categoria).lineLimit(1)
                }
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text((transacao.efeitoNoSaldo < 0 ? "-" : "+") + transacao.valor.moeda)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(transacao.tipo == .receita ? Color.green : (transacao.tipo == .transferencia ? Color.secondary : Color.primary))
                Text(transacao.data.formatted(.dateTime.day().month(.abbreviated).locale(ptBR)) + " · " + transacao.data.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(ptBR)))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .background(Color.cartao, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.borda))
        .contentShape(Rectangle())
    }
}

struct DetalhesSaldoView: View {
    let mes: Int
    @Environment(\.modelContext) private var ctx
    @Query private var recorrencias: [Recorrencia]
    @Environment(\.dismiss) private var dismiss
    @State private var ajustando = false
    @Query private var transacoes: [Transacao]
    @Query private var contas: [Conta]
    @Query(sort: \Carteira.ordem) private var carteiras: [Carteira]

    var body: some View {
        let fin = Financas(transacoes: transacoes, contas: contas, carteiras: carteiras, recorrencias: recorrencias)
        let porCarteira = Dictionary(grouping: fin.transacoes(em: mes).filter { $0.tipo == .gasto && !$0.ehAjuste }, by: \.carteira)
            .map { ItemValor(nome: $0.key, valor: $0.value.reduce(0) { $0 + $1.valor }) }
            .sorted { $0.valor > $1.valor }

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Saldo de \(Mes.nome(mes).lowercased())").font(.system(size: 21, weight: .bold))
                if mes == Mes.indice() {
                    Button {
                        ajustando = true
                    } label: {
                        Label("Ajustar saldo igual ao do banco", systemImage: "equal.circle")
                    }
                    .buttonStyle(EstiloContorno())
                    
                    Text("Digite quanto tem na sua conta agora. O app cria um ajuste com a diferença, sem mexer nos seus gastos e categorias.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    let ajustes = fin.transacoes(em: mes).filter(\.ehAjuste)
                    let ajusteEntrada = ajustes.filter { $0.tipo == .receita }.reduce(0) { $0 + $1.valor }
                    let ajusteSaida = ajustes.filter { $0.tipo == .gasto }.reduce(0) { $0 + $1.valor }
                    let veio = fin.abertura(em: mes)
                    LinhaStat(titulo: "Veio de \(Mes.nome(mes - 1).lowercased())", valor: (veio < 0 ? "-" : "") + abs(veio).moeda)
                    Divider().overlay(Color.borda)
                    LinhaStat(titulo: "Receitas", valor: (fin.receitas(em: mes) - ajusteEntrada).moeda)
                    Divider().overlay(Color.borda)
                    LinhaStat(titulo: "Gastos", valor: "-" + (fin.gastosAvulsos(em: mes) - ajusteSaida).moeda)
                    Divider().overlay(Color.borda)
                    if fin.transferenciasLiquidas(em: mes) != 0 {
                        let tr = fin.transferenciasLiquidas(em: mes)
                        LinhaStat(titulo: "Transferências e caixinhas", valor: (tr >= 0 ? "+" : "-") + abs(tr).moeda)
                        Divider().overlay(Color.borda)
                    }
                    if fin.receitasAReceber(em: mes) > 0 {
                        LinhaStat(titulo: "Receitas fixas a receber", valor: "+" + fin.receitasAReceber(em: mes).moeda)
                        Divider().overlay(Color.borda)
                    }
                    if !ajustes.isEmpty {
                        let liquido = ajusteEntrada - ajusteSaida
                        LinhaStat(titulo: "Correção pra bater com o banco", valor: (liquido >= 0 ? "+" : "-") + abs(liquido).moeda)
                        Divider().overlay(Color.borda)
                    }
                    LinhaStat(titulo: "Contas pagas", valor: "-" + fin.contasPagasFora(em: mes).moeda)
                    Divider().overlay(Color.borda)
                    LinhaStat(titulo: "Faturas pagas", valor: "-" + fin.faturasPagas(em: mes).moeda)
                    Divider().overlay(Color.borda)
                    LinhaStat(titulo: "Saldo hoje", valor: fin.saldo(em: mes).moeda)
                    Divider().overlay(Color.borda)
                    LinhaStat(titulo: "Contas a pagar", valor: "-" + fin.contasAPagar(em: mes).moeda)
                    Divider().overlay(Color.borda)
                    LinhaStat(titulo: "Faturas a pagar", valor: "-" + fin.faturasAPagar(em: mes).moeda)
                    Divider().overlay(Color.borda)
                    LinhaStat(titulo: "Sobra no fim do mês", valor: fin.saldoPrevisto(em: mes).moeda, destaque: true)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .background(Color.cartao2.opacity(0.45), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                if mes == Mes.indice() { SecaoBancos(fin: fin) }

                let pendentes = fin.contasDoMes(mes).filter { !$0.pago(em: mes) }
                let faturas = fin.cartoes().filter { !$0.faturaPaga(em: mes) && fin.fatura($0, em: mes) > 0 }
                if !pendentes.isEmpty || !faturas.isEmpty {
                    Text("O que falta pagar em \(Mes.nome(mes).lowercased())").font(.system(size: 15, weight: .semibold)).padding(.top, 6)
                    VStack(spacing: 0) {
                        ForEach(pendentes) { c in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.parcela(em: mes).map { "\(c.nome) (\($0))" } ?? c.nome).font(.system(size: 15))
                                    Text(c.atrasada(em: mes) ? "venceu dia \(c.dia)" : "vence dia \(c.dia)")
                                        .font(.system(size: 12))
                                        .foregroundStyle(c.atrasada(em: mes) ? Color.red : Color.secondary)
                                }
                                Spacer()
                                Text(c.valor.moeda).fontWeight(.semibold)
                            }
                            .padding(.vertical, 10)
                            Divider().overlay(Color.borda)
                        }
                        ForEach(faturas) { c in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Fatura \(c.nome)").font(.system(size: 15))
                                    Text("vence dia \(c.diaVencimento)").font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(fin.fatura(c, em: mes).moeda).fontWeight(.semibold)
                            }
                            .padding(.vertical, 10)
                            Divider().overlay(Color.borda)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .background(Color.cartao2.opacity(0.45), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    Text("Já pagou alguma? Marque como paga na aba Contas e ela sai daqui.")
                        .font(.footnote).foregroundStyle(.secondary)
                }


                if !porCarteira.isEmpty {
                    Text("Gastos por meio de pagamento").font(.system(size: 15, weight: .semibold)).padding(.top, 6)
                    VStack(spacing: 0) {
                        ForEach(porCarteira) { item in
                            LinhaStat(titulo: item.nome.isEmpty ? "Sem carteira" : item.nome, valor: item.valor.moeda)
                            if item.nome != porCarteira.last?.nome { Divider().overlay(Color.borda) }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .background(Color.cartao2.opacity(0.45), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }

                Text("Contas pagas no cartão de crédito não saem do saldo na hora: entram na fatura do mês seguinte.")
                    .font(.footnote).foregroundStyle(.secondary)

            }
            .padding(24)
            .padding(.top, 10)
        }
        .folha([.large])
        .sheet(isPresented: $ajustando) {
            let f = Financas(transacoes: transacoes, contas: contas, carteiras: carteiras)
            let atual = f.saldo(em: mes)
            EditarValorSheet(titulo: "Saldo no banco agora",
                             subtitulo: "Hoje o app mostra \(atual.moeda). Quanto tem na sua conta?",
                             valor: max(atual, 0)) { real in
                Ajuste.igualar(real: real, atual: atual, carteira: "", mes: mes, fin: f, ctx: ctx)
                Notificacoes.agora("Saldo ajustado", "Agora o app mostra \(real.moeda), igual ao banco.")
            }
        }
    }
}

struct ItemValor: Identifiable {
    let nome: String
    let valor: Double
    var id: String { nome }
}

struct GrupoDia: Identifiable {
    let dia: Date
    let itens: [Transacao]
    var id: Date { dia }
}

enum PeriodoFiltro: String, CaseIterable, Identifiable {
    case tudo, semana, esteMes, mesPassado, tresMeses, ano
    var id: String { rawValue }
    var nome: String {
        switch self {
        case .tudo: return "Todo o período"
        case .semana: return "Últimos 7 dias"
        case .esteMes: return "Este mês"
        case .mesPassado: return "Mês passado"
        case .tresMeses: return "Últimos 3 meses"
        case .ano: return "Este ano"
        }
    }
    func contem(_ d: Date) -> Bool {
        let cal = Calendar.current
        let hoje = Mes.indice()
        switch self {
        case .tudo: return true
        case .semana: return d >= (cal.date(byAdding: .day, value: -7, to: .now) ?? .now)
        case .esteMes: return Mes.indice(d) == hoje
        case .mesPassado: return Mes.indice(d) == hoje - 1
        case .tresMeses: return Mes.indice(d) >= hoje - 2
        case .ano: return cal.component(.year, from: d) == cal.component(.year, from: .now)
        }
    }
}

struct TodasTransacoesView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Transacao.data, order: .reverse) private var transacoes: [Transacao]
    @Query(sort: \Carteira.ordem) private var carteiras: [Carteira]
    @Query(sort: \Categoria.ordem) private var categorias: [Categoria]
    @State private var busca = ""
    @State private var editando: Transacao?
    @State private var periodo: PeriodoFiltro = .tudo
    @State private var tipo: TipoTransacao?
    @State private var categoria: String?
    @State private var carteira: String?
    @State private var minimoTexto = ""
    @State private var maximoTexto = ""
    @State private var editarValor = false
    @State private var soComFoto = false

    private var temFiltro: Bool {
        periodo != .tudo || tipo != nil || categoria != nil || carteira != nil
            || !minimoTexto.isEmpty || !maximoTexto.isEmpty || soComFoto
    }

    private var filtradas: [Transacao] {
        let b = busca.trimmingCharacters(in: .whitespaces).lowercased()
        let minimo = lerValor(minimoTexto)
        let maximo = lerValor(maximoTexto)
        return transacoes.filter { t in
            if !b.isEmpty && !(t.descricao.lowercased().contains(b) || t.categoria.lowercased().contains(b)
                                || t.carteira.lowercased().contains(b)) { return false }
            if !periodo.contem(t.data) { return false }
            if let tipo, t.tipo != tipo { return false }
            if let categoria, t.categoria != categoria { return false }
            if let carteira, t.carteira != carteira { return false }
            if let minimo, t.valor < minimo { return false }
            if let maximo, maximo > 0, t.valor > maximo { return false }
            if soComFoto && t.foto == nil { return false }
            return true
        }
    }

    var body: some View {
        let lista = filtradas
        let grupos = Dictionary(grouping: lista) { Calendar.current.startOfDay(for: $0.data) }
            .map { GrupoDia(dia: $0.key, itens: $0.value) }
            .sorted { $0.dia > $1.dia }
        let gastos = lista.filter { $0.tipo == .gasto && !$0.ehAjuste }.reduce(0) { $0 + $1.valor }
        let receitas = lista.filter { $0.tipo == .receita && !$0.ehAjuste }.reduce(0) { $0 + $1.valor }

        NavigationStack {
            List {
                Section {
                    barraFiltros
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                    HStack {
                        Text("\(lista.count) \(lista.count == 1 ? "transação" : "transações")")
                        Spacer()
                        if gastos > 0 { Text("-\(gastos.moeda)") }
                        if receitas > 0 { Text("+\(receitas.moeda)").foregroundStyle(.green) }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                }
                if grupos.isEmpty {
                    Vazio(titulo: "Nada por aqui", texto: temFiltro ? "Nenhuma transação com esses filtros." : "Nenhuma transação encontrada.")
                        .listRowBackground(Color.clear)
                }
                ForEach(grupos) { grupo in
                    Section(grupo.dia.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(ptBR))) {
                        ForEach(grupo.itens) { t in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Text(t.titulo).font(.system(size: 14, weight: .semibold))
                                        if t.foto != nil {
                                            Image(systemName: "paperclip").font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text("\(t.data.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(ptBR))) · \(t.categoria) · \(t.carteira)").font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text((t.efeitoNoSaldo < 0 ? "-" : "+") + t.valor.moeda)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(t.ehAjuste ? Color.secondary : (t.tipo == .receita ? Color.green : (t.tipo == .transferencia ? Color.secondary : Color.primary)))
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { editando = t }
                            .contextMenu {
                                Button { editando = t } label: { Label("Editar", systemImage: "pencil") }
                                Button(role: .destructive) {
                                    Exclusao.transacao(t, ctx: ctx)
                                } label: { Label("Apagar", systemImage: "trash") }
                            }
                            .swipeActions {
                                Button("Apagar", role: .destructive) {
                                    Exclusao.transacao(t, ctx: ctx)
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.cartao)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.fundo)
            .searchable(text: $busca, prompt: "Buscar por nome, categoria ou carteira")
            .safeAreaInset(edge: .bottom) {
                BarraDesfazer().padding(.bottom, 8)
            }
            .animation(.snappy, value: AppState.shared.desfazer?.id)
            .navigationTitle("Transações")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
            .sheet(item: $editando) { t in RegistroSheet(editando: t) }
            .sheet(isPresented: $editarValor) {
                FiltroValorSheet(minimo: $minimoTexto, maximo: $maximoTexto)
            }
        }
    }

    private var barraFiltros: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Período", selection: $periodo) {
                        ForEach(PeriodoFiltro.allCases) { Text($0.nome).tag($0) }
                    }
                } label: { chip(periodo == .tudo ? "Período" : periodo.nome, ativo: periodo != .tudo) }

                Menu {
                    Button("Todos") { tipo = nil }
                    ForEach(TipoTransacao.allCases) { t in Button(t.nome) { tipo = t } }
                } label: { chip(tipo?.nome ?? "Tipo", ativo: tipo != nil) }

                Menu {
                    Button("Todas") { categoria = nil }
                    ForEach(Array(Set(categorias.map(\.nome) + transacoes.map(\.categoria))).sorted(), id: \.self) { c in
                        Button(c) { categoria = c }
                    }
                } label: { chip(categoria ?? "Categoria", ativo: categoria != nil) }

                Menu {
                    Button("Todas") { carteira = nil }
                    ForEach(carteiras) { c in Button(c.nome) { carteira = c.nome } }
                } label: { chip(carteira ?? "Carteira", ativo: carteira != nil) }

                Button { editarValor = true } label: {
                    chip(textoValor, ativo: !minimoTexto.isEmpty || !maximoTexto.isEmpty)
                }

                Button { soComFoto.toggle() } label: { chip("Com foto", ativo: soComFoto) }

                if temFiltro {
                    Button {
                        periodo = .tudo; tipo = nil; categoria = nil; carteira = nil
                        minimoTexto = ""; maximoTexto = ""; soComFoto = false
                    } label: {
                        Label("Limpar", systemImage: "xmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 10)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
        }
    }

    private var textoValor: String {
        let mi = lerValor(minimoTexto)
        let ma = lerValor(maximoTexto)
        switch (mi, ma) {
        case let (a?, b?): return "\(a.moedaInteira) a \(b.moedaInteira)"
        case let (a?, nil): return "Acima de \(a.moedaInteira)"
        case let (nil, b?): return "Até \(b.moedaInteira)"
        default: return "Valor"
        }
    }

    private func chip(_ texto: String, ativo: Bool) -> some View {
        HStack(spacing: 4) {
            Text(texto).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(ativo ? Color.sobreDestaque : Color.primary)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(ativo ? Color.destaque : Color.cartao, in: Capsule())
        .overlay(Capsule().stroke(Color.borda))
    }
}

struct FiltroValorSheet: View {
    @Binding var minimo: String
    @Binding var maximo: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Filtrar por valor").font(.system(size: 21, weight: .bold))
            HStack(spacing: 10) {
                Text("A partir de").foregroundStyle(.secondary)
                TextField("0,00", text: $minimo).mascaraDinheiro($minimo).multilineTextAlignment(.trailing)
            }
            .campo()
            HStack(spacing: 10) {
                Text("Até").foregroundStyle(.secondary)
                TextField("sem limite", text: $maximo).mascaraDinheiro($maximo).multilineTextAlignment(.trailing)
            }
            .campo()
            Button("Aplicar") { dismiss() }.buttonStyle(EstiloPrincipal())
            Button("Limpar valor") { minimo = ""; maximo = ""; dismiss() }
                .frame(maxWidth: .infinity)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .folha([.height(400)])
    }
}
