import SwiftUI
import SwiftData
import Charts

// MARK: - Cálculo

/// Uma parcela ainda não paga de uma conta que tem fim
struct Parcela {
    let mes: Int
    let valor: Double
    let conta: Conta
}

/// Uma dívida = todas as contas com fim que têm o mesmo nome (ex.: várias "Nubank")
struct Divida: Identifiable {
    let nome: String
    let parcelas: [Parcela]
    var id: String { PlanoCalculo.chave(nome) }
    var restantes: Int { parcelas.count }
    var total: Double { parcelas.reduce(0) { $0 + $1.valor } }
    var fim: Int { parcelas.last?.mes ?? 0 }
    var juros: Double { parcelas.map(\.conta.juros).max() ?? 0 }
    var proxima: Parcela? { parcelas.first }
    var ultima: Parcela? { parcelas.last }
    var contas: [Conta] {
        var vistas = Set<UUID>()
        return parcelas.map(\.conta).filter { vistas.insert($0.chave).inserted }
    }
}

enum MetodoQuitacao: String, CaseIterable, Identifiable {
    case bolaDeNeve, avalanche
    var id: String { rawValue }
    var nome: String { self == .bolaDeNeve ? "Bola de neve" : "Avalanche" }
    var explicacao: String {
        self == .bolaDeNeve
            ? "Quita primeiro as dívidas menores. Cada uma que acaba libera dinheiro pra próxima, e você vê resultado rápido."
            : "Quita primeiro as dívidas com juros mais altos. Economiza mais dinheiro no total."
    }
}

enum PlanoCalculo {
    static func chave(_ nome: String) -> String {
        nome.lowercased().folding(options: .diacriticInsensitive, locale: ptBR).trimmingCharacters(in: .whitespaces)
    }

    static func ultimoMes(_ c: Conta) -> Int {
        let u = c.parcelada ? c.inicio + c.totalParcelas - c.adiantadas - max(c.parcelaAtual, 1) : c.inicio
        return c.fim > 0 ? min(u, c.fim) : u
    }

    /// Conta com fim: parcelada ou única (as fixas que repetem pra sempre ficam de fora)
    static func temFim(_ c: Conta) -> Bool { c.parcelada || !c.repetir }

    private struct Grupo {
        var nome: String
        var parcelas: [Parcela]
    }

    static func dividas(_ contas: [Conta], hoje: Int) -> [Divida] {
        var grupos: [String: Grupo] = [:]
        for c in contas where temFim(c) {
            let ultimo = ultimoMes(c)
            guard ultimo >= hoje else { continue }
            for m in max(c.inicio, hoje)...ultimo where c.ocorre(em: m) && !c.pago(em: m) {
                grupos[chave(c.nome), default: Grupo(nome: c.nome, parcelas: [])]
                    .parcelas.append(Parcela(mes: m, valor: c.valor, conta: c))
            }
        }
        return grupos.values
            .filter { !$0.parcelas.isEmpty }
            .map { Divida(nome: $0.nome, parcelas: $0.parcelas.sorted { $0.mes < $1.mes }) }
    }

    static func ordenar(_ d: [Divida], _ metodo: MetodoQuitacao) -> [Divida] {
        switch metodo {
        case .bolaDeNeve:
            return d.sorted { ($0.total, $0.fim) < ($1.total, $1.fim) }
        case .avalanche:
            return d.sorted { $0.juros != $1.juros ? $0.juros > $1.juros : $0.total < $1.total }
        }
    }

    /// Simula mês a mês. Cada mês as parcelas vencem normalmente; o valor extra só é usado
    /// se sobrar dinheiro naquele mês de verdade, e o que as dívidas já quitadas deixam de
    /// cobrar vai pra próxima da fila (bola de neve).
    static func simular(_ ordem: [Divida], extra: Double, hoje: Int,
                        sobraMes: (Int) -> Double) -> (fim: Int, fimPorConta: [String: Int]) {
        var resta: [String: [Parcela]] = [:]
        for d in ordem { resta[d.id] = d.parcelas }
        var fimPor: [String: Int] = [:]
        let fimMax = ordem.map(\.fim).max() ?? hoje
        var caixa = 0.0
        var m = hoje
        while resta.values.contains(where: { !$0.isEmpty }) && m <= fimMax {
            var previsto = 0.0
            var pago = 0.0
            for d in ordem {
                previsto += d.parcelas.filter { $0.mes == m }.reduce(0) { $0 + $1.valor }
                var lista = resta[d.id] ?? []
                pago += lista.filter { $0.mes <= m }.reduce(0) { $0 + $1.valor }
                lista.removeAll { $0.mes <= m }
                resta[d.id] = lista
                if lista.isEmpty && fimPor[d.id] == nil { fimPor[d.id] = m }
            }
            let liberado = max(0, previsto - pago)
            caixa += liberado + min(max(extra, 0), max(0, sobraMes(m)))
            for d in ordem {
                var lista = resta[d.id] ?? []
                while let u = lista.last, caixa >= u.valor {
                    caixa -= u.valor
                    lista.removeLast()
                }
                resta[d.id] = lista
                if lista.isEmpty {
                    if fimPor[d.id] == nil { fimPor[d.id] = m }
                } else {
                    break
                }
            }
            m += 1
        }
        return (fimPor.values.max() ?? hoje, fimPor)
    }

    /// Quanto já foi pago das dívidas que ainda estão correndo
    /// (parcelas de antes de cadastrar + meses marcados como pagos + adiantadas)
    static func jaPago(_ contas: [Conta], hoje: Int) -> Double {
        contas.filter { temFim($0) && ultimoMes($0) >= hoje }.reduce(0) { soma, c in
            let antes = c.parcelada ? Double(max(c.parcelaAtual, 1) - 1) : 0
            return soma + (antes + Double(c.pagamentos.count + c.adiantadas)) * c.valor
        }
    }

    /// Quanto custa atrasar a próxima parcela: juros da conta (ou 1% a.m. estimado) + multa de 2%
    static func custoAtraso(_ d: Divida) -> (valor: Double, estimado: Bool) {
        let parcela = d.proxima?.valor ?? 0
        if d.juros > 0 { return (parcela * (d.juros / 100 + 0.02), false) }
        return (parcela * 0.03, true)
    }

    /// Quanto faltava pagar no começo de cada mês (pra o gráfico da dívida caindo)
    static func dividaNoMes(_ contas: [Conta], _ m: Int) -> Double {
        contas.filter(temFim).reduce(0) { soma, c in
            let ultimo = ultimoMes(c)
            guard ultimo >= m else { return soma }
            let parcelas = (max(m, c.inicio)...ultimo).filter { c.ocorre(em: $0) }.count
            return soma + Double(parcelas) * c.valor
        }
    }

    /// Fechou acordo à vista: registra o pagamento e tira todas as parcelas que faltavam
    @MainActor
    static func quitarAVista(_ d: Divida, valor: Double, ctx: ModelContext) {
        let parcelas = d.parcelas
        let t = Transacao(tipo: .gasto, valor: valor,
                          categoria: d.proxima?.conta.categoria.isEmpty == false ? (d.proxima?.conta.categoria ?? "Outros") : "Outros",
                          carteira: "", descricao: "Quitação à vista: \(d.nome)")
        withAnimation {
            ctx.insert(t)
            for p in parcelas { p.conta.excluir(em: p.mes) }
            try? ctx.save()
        }
        Notificacoes.reagendar(ctx)
        Notificacoes.agora("\(d.nome) quitada! 🎉", "Economia de \((d.total - valor).moeda) com o acordo à vista.")
        AppState.shared.oferecerDesfazer("\(d.nome) quitada à vista") {
            for p in parcelas { p.conta.restaurar(em: p.mes) }
            ctx.delete(t)
            try? ctx.save()
            Notificacoes.reagendar(ctx)
        }
    }

    /// Paga agora a última parcela da dívida (encurta o prazo), com opção de desfazer
    @MainActor
    static func adiantar(_ d: Divida, ctx: ModelContext) {
        guard let p = d.ultima else { return }
        let c = p.conta
        let t = Transacao(tipo: .gasto, valor: p.valor, categoria: c.categoria.isEmpty ? "Outros" : c.categoria,
                          carteira: "", descricao: "Adiantamento: \(c.nome)")
        let parcelada = c.parcelada
        withAnimation {
            ctx.insert(t)
            if parcelada { c.adiantadas += 1 } else { c.excluir(em: p.mes) }
            try? ctx.save()
        }
        Notificacoes.reagendar(ctx)
        AppState.shared.oferecerDesfazer("Parcela de \(c.nome) adiantada") {
            if parcelada { c.adiantadas = max(0, c.adiantadas - 1) } else { c.restaurar(em: p.mes) }
            ctx.delete(t)
            try? ctx.save()
            Notificacoes.reagendar(ctx)
        }
    }
}

func mesAno(_ i: Int) -> String {
    "\(Mes.curto(i).lowercased())/\(String(format: "%02d", Mes.ano(i) % 100))"
}

// MARK: - Tela

struct PlanoQuitacaoView: View {
    @Environment(\.modelContext) private var ctx
    @Query private var contas: [Conta]
    @Query private var recorrencias: [Recorrencia]
    @Query private var transacoes: [Transacao]
    @Query(sort: \Carteira.ordem) private var carteiras: [Carteira]
    @AppStorage("renda") private var rendaManual: Double = 0
    @AppStorage("metodoQuitacao") private var metodoRaw = MetodoQuitacao.bolaDeNeve.rawValue
    @AppStorage("extraQuitacao") private var extra: Double = -1
    @State private var editarRenda = false
    @State private var adiantando: Divida?
    @State private var editando: Conta?
    @State private var negociando: Divida?
    @State private var mesAberto: Int?

    private var metodo: MetodoQuitacao { MetodoQuitacao(rawValue: metodoRaw) ?? .bolaDeNeve }

    var body: some View {
        let hoje = Mes.indice()
        let fin = Financas(transacoes: transacoes, contas: contas, carteiras: carteiras, recorrencias: recorrencias)
        let dividas = PlanoCalculo.dividas(contas, hoje: hoje)
        let ordem = PlanoCalculo.ordenar(dividas, metodo)
        let totalDevido = dividas.reduce(0) { $0 + $1.total }
        let fimNatural = dividas.map(\.fim).max() ?? hoje
        let registrada = (hoje...(hoje + 2)).map { fin.receitas(em: $0) + fin.receitasAReceber(em: $0) }.max() ?? 0
        let renda = rendaManual > 0 ? rendaManual : registrada
        let mediaGastos = mediaGastosAvulsos(fin, hoje: hoje)
        let contasDe: (Int) -> Double = { m in fin.contasDoMes(m).reduce(0) { $0 + $1.valor } }
        let sobraMes: (Int) -> Double = { m in renda - contasDe(m) - mediaGastos }
        // mês mais apertado entre este e os próximos 3
        let apertado = (hoje...(hoje + 3)).min { sobraMes($0) < sobraMes($1) } ?? hoje
        let sobra = sobraMes(apertado)
        let extraAtual = extra >= 0 ? extra : max(0, (sobra / 50).rounded(.down) * 50)
        let simulado = PlanoCalculo.simular(ordem, extra: extraAtual, hoje: hoje, sobraMes: sobraMes)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Cabecalho(sub: "Plano de quitação", titulo: "Quitar")
                SecaoCaixinhas()

                if dividas.isEmpty {
                    Vazio(icone: "checkmark.seal", titulo: "Nenhuma dívida com fim",
                          texto: "Contas parceladas ou únicas deste mês em diante aparecem aqui. As que repetem todo mês ficam em Cobranças fixas.")
                        .cartao(18)
                } else {
                    resumo(total: totalDevido, pago: PlanoCalculo.jaPago(contas, hoje: hoje),
                           parcelas: dividas.reduce(0) { $0 + $1.restantes }, fim: fimNatural, dividas: dividas)
                    mesAMes(fin: fin, hoje: hoje, fim: fimNatural)
                    dinheiroExtra(fin: fin, ordem: ordem, hoje: hoje, media: mediaGastos)
                    graficoDivida(hoje: hoje, fim: fimNatural)
                }
                cartaoSobra(renda: renda, registrada: rendaManual == 0 && registrada > 0,
                            mes: apertado, compromisso: contasDe(apertado), media: mediaGastos, sobra: sobra)
                if !dividas.isEmpty {
                    linhaDoTempo(fin: fin, hoje: hoje, fim: max(fimNatural, hoje + 1))
                    simulador(extra: extraAtual, fimNatural: fimNatural, fimPlano: simulado.fim, hoje: hoje)
                    prioridadeSeFaltar(dividas, hoje: hoje)
                    ordemQuitacao(ordem, fimPlano: simulado.fimPorConta, hoje: hoje)
                }
                let fixas = contas.filter { !PlanoCalculo.temFim($0) && ($0.ocorre(em: hoje) || $0.ocorre(em: hoje + 1)) }
                    .sorted { $0.valor > $1.valor }
                if !fixas.isEmpty {
                    cobrancasFixas(fixas, hoje: hoje)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(Color.fundo)
        .sheet(item: $editando) { c in FormContaView(conta: c, mesInicial: Mes.indice()) }
        .sheet(item: $negociando) { d in NegociarSheet(divida: d) }
        .sheet(isPresented: $editarRenda) {
            EditarValorSheet(titulo: "Sua renda por mês",
                             subtitulo: "Quanto entra por mês, somando salário e outras receitas fixas",
                             valor: renda) { rendaManual = $0 }
        }
        .confirmationDialog("Adiantar uma parcela de \(adiantando?.nome ?? "")?",
                            isPresented: Binding(get: { adiantando != nil }, set: { if !$0 { adiantando = nil } }),
                            titleVisibility: .visible) {
            Button("Adiantar \(adiantando?.ultima?.valor.moeda ?? "")") {
                if let adiantando { PlanoCalculo.adiantar(adiantando, ctx: ctx) }
                adiantando = nil
            }
        } message: {
            Text("Registra um gasto com esse valor hoje e tira a última parcela, a de \(adiantando?.ultima.map { mesAno($0.mes) } ?? "").")
        }
    }

    private func mediaGastosAvulsos(_ fin: Financas, hoje: Int) -> Double {
        let anteriores = ((hoje - 3)...(hoje - 1)).map { fin.gastosTransacoes(em: $0) }.filter { $0 > 0 }
        if !anteriores.isEmpty { return anteriores.reduce(0, +) / Double(anteriores.count) }
        return fin.gastosTransacoes(em: hoje)
    }

    // MARK: Partes

    private func resumo(total: Double, pago: Double, parcelas: Int, fim: Int, dividas: [Divida]) -> some View {
        let p = pago + total > 0 ? pago / (pago + total) : 0
        let cal = Calendar.current
        let ultimaData = dividas.compactMap { d in d.ultima.map { $0.conta.vencimento(em: $0.mes) } }.max()
            ?? Mes.data(fim, dia: 28)
        let dias = max(0, cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: ultimaData).day ?? 0)
        return VStack(alignment: .leading, spacing: 8) {
            Text("VOCÊ AINDA DEVE").font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            Text(total.moeda).font(.system(size: 32, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.6)
            BarraProgresso(p: p, cor: .green, altura: 6).padding(.vertical, 4)
            HStack {
                Text("Já pagou \(pago.moeda)")
                Spacer()
                Text("\(porcento(p)) do caminho").fontWeight(.semibold)
            }
            .font(.system(size: 13))
            Divider().overlay(Color.borda).padding(.vertical, 4)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LIVRE EM").font(.system(size: 11, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                    Text("\(Mes.nome(fim)) de \(String(Mes.ano(fim)))").font(.system(size: 20, weight: .bold))
                    Text("\(parcelas) parcelas pela frente").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(dias)").font(.system(size: 34, weight: .heavy)).lineLimit(1)
                    Text(dias == 1 ? "dia" : "dias").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .cartao(20)
    }

    /// Quanto você paga em cada mês até a última parcela (toque no mês pra ver as contas)
    private func mesAMes(fin: Financas, hoje: Int, fim: Int) -> some View {
        let meses = Array(hoje...max(fim, hoje + 1))
        return VStack(alignment: .leading, spacing: 0) {
            Text("QUANTO VOCÊ PAGA MÊS A MÊS").font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                .padding(.bottom, 8)
            ForEach(meses, id: \.self) { m in
                let contasMes = fin.contasDoMes(m)
                let total = contasMes.reduce(0) { $0 + $1.valor }
                let falta = contasMes.filter { !$0.pago(em: m) }.reduce(0) { $0 + $1.valor }
                Button {
                    withAnimation(.snappy) { mesAberto = mesAberto == m ? nil : m }
                } label: {
                    HStack {
                        Text(mesAno(m)).font(.system(size: 15, weight: m == hoje ? .bold : .regular))
                        if m == hoje && falta < total {
                            Text("falta \(falta.moeda)").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(total.moeda).font(.system(size: 15, weight: .semibold))
                        Image(systemName: mesAberto == m ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if mesAberto == m {
                    VStack(spacing: 6) {
                        ForEach(contasMes) { c in
                            HStack {
                                Image(systemName: c.pago(em: m) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(c.pago(em: m) ? Color.green : Color.secondary)
                                Text(c.nome).font(.system(size: 13)).lineLimit(1)
                                Text("dia \(c.dia)").font(.system(size: 12)).foregroundStyle(.secondary)
                                Spacer()
                                Text(c.valor.moeda).font(.system(size: 13))
                            }
                        }
                    }
                    .padding(.bottom, 10)
                }
                if m != meses.last { Divisor() }
            }
        }
        .cartao(20)
    }

    /// Quando deve sobrar dinheiro no mês, sugere adiantar a dívida certa
    @ViewBuilder
    private func dinheiroExtra(fin: Financas, ordem: [Divida], hoje: Int, media: Double) -> some View {
        let cal = Calendar.current
        let diasNoMes = Double(cal.range(of: .day, in: .month, for: .now)?.count ?? 30)
        let restam = diasNoMes - Double(cal.component(.day, from: .now)) + 1
        let reserva = max(0, media * restam / diasNoMes)
        let sobra = fin.saldoPrevisto(em: hoje) - reserva
        if let alvo = ordem.first, let ult = alvo.ultima, sobra > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("DINHEIRO EXTRA PRA DÍVIDA").font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                Text("Deve sobrar \(sobra.moeda) em \(Mes.nome(hoje).lowercased())").font(.system(size: 17, weight: .bold))
                if sobra >= ult.valor {
                    Text(alvo.restantes == 1
                         ? "Dá pra quitar \(alvo.nome) de vez agora (\(ult.valor.moeda))."
                         : "Adiantando a última parcela de \(alvo.nome) (\(ult.valor.moeda)), ela acaba em \(mesAno(alvo.fim - 1)) em vez de \(mesAno(alvo.fim)).")
                        .font(.system(size: 14))
                    if alvo.juros > 0 {
                        let economia = ult.valor * alvo.juros / 100 * Double(max(0, ult.mes - hoje))
                        Text("Economia estimada de \(economia.moeda) em juros.")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.green)
                    }
                    Button { adiantando = alvo } label: {
                        Label("Adiantar \(ult.valor.moeda) agora", systemImage: "bolt.fill")
                    }
                    .buttonStyle(EstiloPrincipal())
                    .padding(.top, 4)
                } else {
                    Text("Faltam \((ult.valor - sobra).moeda) pra adiantar uma parcela de \(alvo.nome). Guarde numa caixinha e adiante quando juntar.")
                        .font(.system(size: 14))
                }
                Text("Já separamos \(reserva.moeda) pros gastos do dia a dia até o fim do mês (pela sua média).")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .cartao(20)
        }
    }

    private func cartaoSobra(renda: Double, registrada: Bool, mes: Int, compromisso: Double, media: Double, sobra: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("QUANTO SOBRA").font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                    Text("no mês mais apertado: \(Mes.nome(mes).lowercased())").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(renda > 0 ? sobra.moeda : "—")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(renda == 0 ? Color.secondary : (sobra >= 0 ? Color.green : Color.red))
            }
            .padding(.bottom, 6)
            Button { editarRenda = true } label: {
                HStack {
                    Text(renda > 0 ? "Renda" : "Informe sua renda")
                    Spacer()
                    Text(renda > 0 ? renda.moeda : "tocar aqui").fontWeight(.semibold)
                    Image(systemName: "pencil").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .font(.system(size: 15))
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divisor()
            LinhaStat(titulo: "Contas de \(Mes.nome(mes).lowercased())", valor: "-" + compromisso.moeda)
            Divisor()
            LinhaStat(titulo: "Média dos gastos do dia a dia", valor: "-" + media.moeda)
            if registrada {
                Text("Renda = maior receita registrada entre este mês e os próximos 2. Toque pra ajustar.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 6)
            }
            if renda > 0 && sobra < 0 {
                Text("Em \(Mes.nome(mes).lowercased()) as contas e gastos passam da renda. Antes de adiantar, corte ou adie cobranças desse mês.")
                    .font(.system(size: 12)).foregroundStyle(.red).padding(.top, 6)
            }
        }
        .cartao(20)
    }

    private func linhaDoTempo(fin: Financas, hoje: Int, fim: Int) -> some View {
        let meses = Array(hoje...min(fim + 1, hoje + 35))
        let pontos = meses.map { PontoMes(mes: $0, valor: fin.contasDoMes($0).reduce(0) { $0 + $1.valor }) }
        let valor: (Int) -> Double = { i in fin.contasDoMes(hoje + i).reduce(0) { $0 + $1.valor } }
        return VStack(alignment: .leading, spacing: 12) {
            Text("CONTAS POR MÊS ATÉ FICAR LIVRE").font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            Chart(pontos) { p in
                BarMark(x: .value("Mês", mesAno(p.mes)), y: .value("Total", p.valor))
                    .cornerRadius(5)
                    .foregroundStyle(p.mes == hoje ? Color.primary : Color.cartao2)
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().font(.system(size: 9)) }
            }
            .frame(height: 130)
            HStack(spacing: 0) {
                marco("Agora", valor(0))
                marco("Em 3 meses", valor(3))
                marco("Em 6 meses", valor(6))
                marco("Em 12 meses", valor(12))
            }
        }
        .cartao(20)
    }

    private func marco(_ titulo: String, _ v: Double) -> some View {
        VStack(spacing: 3) {
            Text(titulo).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(v.moedaInteira).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private func simulador(extra: Double, fimNatural: Int, fimPlano: Int, hoje: Int) -> some View {
        let ganho = fimNatural - fimPlano
        return VStack(alignment: .leading, spacing: 12) {
            Text("SIMULADOR").font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            HStack {
                Text("Adiantar por mês").font(.system(size: 15))
                Spacer()
                Button { self.extra = max(0, extra - 50) } label: { Image(systemName: "minus") }
                    .frame(width: 34, height: 34).background(Color.cartao2, in: Circle())
                Text(extra.moedaInteira).font(.system(size: 17, weight: .bold)).frame(minWidth: 90)
                Button { self.extra = extra + 50 } label: { Image(systemName: "plus") }
                    .frame(width: 34, height: 34).background(Color.cartao2, in: Circle())
            }
            .buttonStyle(.plain)
            Picker("Método", selection: $metodoRaw) {
                ForEach(MetodoQuitacao.allCases) { m in Text(m.nome).tag(m.rawValue) }
            }
            .pickerStyle(.segmented)
            Text(metodo.explicacao).font(.system(size: 12)).foregroundStyle(.secondary)
            if metodo == .avalanche && !contas.contains(where: { $0.juros > 0 }) {
                Text("Pra avalanche funcionar, coloque os juros ao mês em cada conta (Editar conta).")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 4) {
                if ganho > 0 {
                    Text("Livre em \(mesAno(fimPlano)) em vez de \(mesAno(fimNatural))")
                        .font(.system(size: 18, weight: .bold))
                    Text("\(ganho) \(ganho == 1 ? "mês" : "meses") antes, adiantando até \(extra.moedaInteira) nos meses em que sobra dinheiro e usando o que cada dívida quitada libera.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                } else {
                    Text("Livre em \(mesAno(fimNatural))").font(.system(size: 18, weight: .bold))
                    Text("Aumente o valor pra adiantar e veja quantos meses você ganha.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cartao2.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .cartao(20)
    }

    /// Botão "•••" com Editar / Remover só deste mês / Remover todos os meses
    private func menuConta(_ c: Conta, hoje: Int) -> some View {
        Menu {
            Button { editando = c } label: { Label("Editar", systemImage: "pencil") }
            if c.recorrente {
                Button(role: .destructive) {
                    Exclusao.contaSoNoMes(c, mes: hoje, ctx: ctx)
                } label: { Label("Remover só de \(Mes.nome(hoje).lowercased())", systemImage: "calendar.badge.minus") }
            }
            Button(role: .destructive) {
                Exclusao.conta(c, ctx: ctx)
            } label: { Label(c.recorrente ? "Remover todos os meses" : "Remover", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(Color.cartao2, in: Circle())
        }
    }

    private func cobrancasFixas(_ lista: [Conta], hoje: Int) -> some View {
        let total = lista.reduce(0) { $0 + $1.valor }
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("COBRANÇAS FIXAS DESTE MÊS").font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                Text("\(total.moeda) no total. Cada uma que você cortar vira dinheiro pra quitar mais rápido.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.leading, 6)
            VStack(spacing: 0) {
                ForEach(lista) { c in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.nome).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Text("\(c.tipoNome) · vence dia \(c.dia)\(c.pago(em: hoje) ? " · pago" : "")")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(c.valor.moeda).font(.system(size: 15, weight: .bold))
                        menuConta(c, hoje: hoje)
                    }
                    .padding(.vertical, 10)
                    if c.chave != lista.last?.chave { Divisor() }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
            .background(Color.cartao, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.borda))
        }
    }

    private func descricao(_ d: Divida) -> String {
        var t = "\(d.restantes) \(d.restantes == 1 ? "parcela" : "parcelas")"
        if let p = d.proxima { t += " · próxima \(p.valor.moeda) em \(mesAno(p.mes))" }
        if d.juros > 0 { t += " · \(d.juros.formatted(.number.precision(.fractionLength(0...2)).locale(ptBR)))% a.m." }
        return t
    }

    /// Gráfico do total que faltava pagar em cada mês (a linha descendo até zero)
    private func graficoDivida(hoje: Int, fim: Int) -> some View {
        let inicio = max(hoje - 6, (contas.filter(PlanoCalculo.temFim).map(\.inicio).min() ?? hoje))
        let meses = Array(inicio...max(fim + 1, hoje + 1)).suffix(30)
        let pontos = meses.map { PontoMes(mes: $0, valor: PlanoCalculo.dividaNoMes(contas, $0)) }
        let antes = pontos.first?.valor ?? 0
        let agora = PlanoCalculo.dividaNoMes(contas, hoje)
        return VStack(alignment: .leading, spacing: 10) {
            Text("SUA DÍVIDA MÊS A MÊS").font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            Chart(pontos) { p in
                AreaMark(x: .value("Mês", mesAno(p.mes)), y: .value("Dívida", p.valor))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Color.primary.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Mês", mesAno(p.mes)), y: .value("Dívida", p.valor))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.primary)
                if p.mes == hoje {
                    PointMark(x: .value("Mês", mesAno(p.mes)), y: .value("Dívida", p.valor))
                        .foregroundStyle(Color.green)
                        .symbolSize(70)
                }
            }
            .chartYAxis(.hidden)
            .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 9)) } }
            .frame(height: 140)
            if antes > agora && antes > 0 {
                Text("Desde \(mesAno(pontos.first?.mes ?? hoje)) você já tirou \((antes - agora).moeda) da dívida. 💪")
                    .font(.system(size: 12)).foregroundStyle(.green)
            } else {
                Text("Cada parcela paga e cada adiantamento fazem essa linha descer mais rápido.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .cartao(20)
    }

    /// Se o dinheiro não der pra tudo neste mês: o que pagar primeiro (o que mais custa atrasar)
    @ViewBuilder
    private func prioridadeSeFaltar(_ dividas: [Divida], hoje: Int) -> some View {
        let doMes = dividas.filter { ($0.proxima?.mes ?? Int.max) <= hoje }
            .sorted { PlanoCalculo.custoAtraso($0).valor > PlanoCalculo.custoAtraso($1).valor }
        if doMes.count >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                Label("SE NÃO DER PRA PAGAR TUDO ESTE MÊS", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Text("Pague primeiro o que mais custa atrasar:").font(.system(size: 13)).foregroundStyle(.secondary)
                ForEach(Array(doMes.prefix(4).enumerated()), id: \.element.id) { i, d in
                    HStack {
                        Text("\(i + 1). \(d.nome)").font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text("atraso ~\(PlanoCalculo.custoAtraso(d).valor.moeda)").font(.system(size: 12)).foregroundStyle(.orange)
                    }
                }
            }
            .cartao(20)
        }
    }

    /// "•••" de uma dívida: editar a próxima conta, remover a próxima parcela ou remover tudo
    private func menuDivida(_ d: Divida) -> some View {
        Menu {
            if let p = d.proxima {
                Button { editando = p.conta } label: { Label("Editar", systemImage: "pencil") }
                Button(role: .destructive) {
                    Exclusao.contaSoNoMes(p.conta, mes: p.mes, ctx: ctx)
                } label: { Label("Remover parcela de \(mesAno(p.mes))", systemImage: "calendar.badge.minus") }
            }
            Button { negociando = d } label: { Label("Negociar à vista", systemImage: "hand.raised") }
            Button(role: .destructive) {
                Exclusao.contas(d.contas, nome: d.nome, ctx: ctx)
            } label: { Label("Remover tudo (\(d.restantes)x)", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(Color.cartao2, in: Circle())
        }
    }

    private func ordemQuitacao(_ ordem: [Divida], fimPlano: [String: Int], hoje: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ORDEM DE QUITAÇÃO").font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                .padding(.leading, 6)
            ForEach(Array(ordem.enumerated()), id: \.element.id) { i, d in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(i + 1)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.sobreDestaque)
                        .frame(width: 26, height: 26)
                        .background(Color.destaque, in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(d.nome).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Text(d.total.moeda).font(.system(size: 15, weight: .bold))
                            menuDivida(d)
                        }
                        Text(descricao(d))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        let custo = PlanoCalculo.custoAtraso(d)
                        if custo.valor > 0 {
                            Text("Atrasar a próxima custa ~\(custo.valor.moeda)\(custo.estimado ? " (estimado: multa 2% + juros 1%)" : "")")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        HStack(spacing: 6) {
                            Text("Termina \(mesAno(d.fim))").foregroundStyle(.secondary)
                            if let f = fimPlano[d.id], f < d.fim {
                                Text("→ \(mesAno(f)) com o plano").foregroundStyle(.green)
                            }
                        }
                        .font(.system(size: 12))
                        Button { adiantando = d } label: {
                            Label("Adiantar parcela", systemImage: "forward.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(Color.cartao2, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
                .cartao(16)
            }
        }
    }
}

/// Simula pagar o restante de uma dívida à vista com desconto e registra o acordo
struct NegociarSheet: View {
    let divida: Divida
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx
    @State private var desconto: Double = 20
    @State private var confirmar = false

    var body: some View {
        let total = divida.total
        let aVista = (total * (1 - desconto / 100) * 100).rounded() / 100
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Negociar \(divida.nome)").font(.system(size: 21, weight: .bold))
                Text("Ligue ou fale no chat com o credor e peça desconto pra quitar o que falta de uma vez. Parcelamentos e financiamentos costumam dar de 10% a 30%.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    LinhaStat(titulo: "Falta pagar parcelado", valor: total.moeda)
                    Divisor()
                    HStack {
                        Text("Desconto pedido").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(desconto))%").fontWeight(.semibold)
                    }
                    .padding(.top, 8)
                    Slider(value: $desconto, in: 0...70, step: 5)
                        .tint(.green)
                    Divisor()
                    LinhaStat(titulo: "Pagaria à vista", valor: aVista.moeda, destaque: true)
                    Text("Economia de \((total - aVista).moeda)")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.green)
                }
                .padding(18)
                .background(Color.cartao2.opacity(0.45), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button("Fechei acordo por \(aVista.moeda)") { confirmar = true }
                    .buttonStyle(EstiloPrincipal(ativo: aVista > 0))
                Text("Ao confirmar, o app registra o pagamento de \(aVista.moeda) hoje e tira as \(divida.restantes) parcelas que faltavam.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .folha([.large])
        .confirmationDialog("Registrar o acordo?", isPresented: $confirmar, titleVisibility: .visible) {
            Button("Sim, paguei \(aVista.moeda)") {
                PlanoCalculo.quitarAVista(divida, valor: aVista, ctx: ctx)
                dismiss()
            }
        }
    }
}
