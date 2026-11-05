import SwiftUI
import SwiftData

/// "isso é o que você realmente gasta" — botão de alvo na aba Análise
struct InsightsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx
    @Query private var transacoes: [Transacao]
    @Query private var contas: [Conta]
    @Query(sort: \Carteira.ordem) private var carteiras: [Carteira]
    @Query(sort: \Categoria.ordem) private var categorias: [Categoria]
    @Query private var limites: [LimiteMensal]
    @AppStorage("renda") private var renda: Double = 0
    @State private var pagina = 0
    @State private var editandoRenda = false
    @State private var rendaTexto = ""
    @FocusState private var focoRenda: Bool

    private struct Resumo {
        var media: Double = 0
        var essencial: Double = 0
        var desejo: Double = 0
        var porCategoria: [ItemValor] = []
    }

    /// Média dos últimos 3 meses que têm gastos
    private var resumo: Resumo {
        let fin = Financas(transacoes: transacoes, contas: contas, carteiras: carteiras, limites: limites)
        let hoje = Mes.indice()
        let meses = ((hoje - 2)...hoje).filter { fin.gastoTotal(em: $0) > 0 }
        guard !meses.isEmpty else { return Resumo() }
        var soma: [String: Double] = [:]
        for m in meses {
            for (k, v) in fin.gastoPorCategoria(em: m) { soma[k, default: 0] += v / Double(meses.count) }
        }
        var r = Resumo()
        r.media = soma.values.reduce(0, +)
        for (k, v) in soma {
            let essencial = categorias.first { $0.nome == k && $0.tipo == .gasto }?.essencial ?? true
            if essencial { r.essencial += v } else { r.desejo += v }
        }
        r.porCategoria = soma.map { ItemValor(nome: $0.key, valor: $0.value) }.sorted { $0.valor > $1.valor }
        return r
    }

    var body: some View {
        let r = resumo
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).padding(8)
                }
                .buttonStyle(.plain)
                Spacer()
                Pontos(total: 3, atual: pagina)
                Spacer()
                Color.clear.frame(width: 40, height: 1)
            }
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch pagina {
                    case 0: paginaGasto(r)
                    case 1: paginaAjuste(r)
                    default: paginaPlano(r)
                    }
                }
                .padding(.top, 34)
            }
            .scrollDismissesKeyboard(.interactively)

            Button(pagina < 2 ? "continuar" : "fechar") {
                if pagina < 2 { withAnimation { pagina += 1 } } else { dismiss() }
            }
            .buttonStyle(EstiloPrincipal())
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
        .background(Color.fundo.ignoresSafeArea())
    }

    // MARK: Página 1

    @ViewBuilder
    private func paginaGasto(_ r: Resumo) -> some View {
        let total = max(r.media, 0.01)
        let pe = r.essencial / total
        Text("antes de tudo").foregroundStyle(.secondary)
        Text("isso é o que você realmente gasta").font(.system(size: 27, weight: .heavy)).tracking(-1)

        VStack(alignment: .leading, spacing: 14) {
            Text("VOCÊ GASTA EM MÉDIA").font(.system(size: 14, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            Text(r.media.moedaInteira).font(.system(size: 30, weight: .heavy))
            GeometryReader { g in
                HStack(spacing: 3) {
                    Capsule().fill(Color.primary).frame(width: max(0, g.size.width * pe - 1.5))
                    Capsule().fill(Color.cartao2)
                }
            }
            .frame(height: 12)
            Text("\(porcento(pe)) em essencial · \(porcento(r.media > 0 ? 1 - pe : 0)) em desejo")
                .foregroundStyle(.secondary)
            if renda > 0 {
                let sobra = renda - r.media
                Text("\(sobra >= 0 ? "sobra" : "falta") \(abs(sobra).moedaInteira) · \(porcento(abs(sobra) / renda)) da sua renda")
                    .foregroundStyle(.secondary)
            }
        }
        .cartao(26)

        Text(r.media == 0
             ? "ainda não tem gastos suficientes pra calcular. registre por alguns dias e volte aqui."
             : (r.essencial >= r.desejo
                ? "seu essencial pesa mais que o desejo hoje — comum, e não é problema."
                : "o desejo está pesando mais que o essencial — dá pra ajustar sem sofrimento."))
            .foregroundStyle(.secondary)

        if renda == 0 || editandoRenda {
            if editandoRenda {
                HStack {
                    TextField("quanto entra por mês", text: $rendaTexto)
                        .mascaraDinheiro($rendaTexto)
                        .focused($focoRenda)
                    Button("OK") {
                        renda = lerValor(rendaTexto) ?? 0
                        editandoRenda = false
                        focoRenda = false
                    }
                    .fontWeight(.semibold)
                }
                .campo()
            } else {
                Button {
                    editandoRenda = true
                    focoRenda = true
                } label: {
                    HStack {
                        Text("quer saber quanto sobra? me diz sua renda")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .foregroundStyle(.secondary)
                    .campo()
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Página 2

    @ViewBuilder
    private func paginaAjuste(_ r: Resumo) -> some View {
        Text("depois").foregroundStyle(.secondary)
        Text("onde dá pra ajustar").font(.system(size: 27, weight: .heavy)).tracking(-1)
        if r.porCategoria.isEmpty {
            Text("assim que você registrar alguns gastos, mostramos aqui as categorias que mais pesam.")
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(r.porCategoria.prefix(3)) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.nome).font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Text(item.valor.moedaInteira).fontWeight(.semibold)
                        }
                        Text("\(porcento(item.valor / max(r.media, 0.01))) do que você gasta · cortar 10% aqui = \((item.valor * 0.1).moedaInteira) por mês")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 14)
                    if item.nome != r.porCategoria.prefix(3).last?.nome { Divider().overlay(Color.borda) }
                }
            }
            .cartao(22)
            Text("pequenos cortes nas categorias grandes fazem mais diferença do que zerar as pequenas.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Página 3

    @ViewBuilder
    private func paginaPlano(_ r: Resumo) -> some View {
        let base = renda > 0 ? min(renda * 0.8, max(r.media * 0.9, 1)) : r.media * 0.9
        let sugestao = (base / 50).rounded() * 50
        Text("por fim").foregroundStyle(.secondary)
        Text("um limite que cabe no seu mês").font(.system(size: 27, weight: .heavy)).tracking(-1)
        VStack(alignment: .leading, spacing: 10) {
            Text("LIMITE SUGERIDO").font(.system(size: 14, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            Text(sugestao > 0 ? sugestao.moedaInteira : "—").font(.system(size: 30, weight: .heavy))
            Text(renda > 0 ? "até 80% da sua renda, um pouco abaixo da sua média" : "10% abaixo da sua média dos últimos meses")
                .foregroundStyle(.secondary)
        }
        .cartao(26)
        if sugestao > 0 {
            Button("usar esse limite a partir deste mês") {
                let m = Mes.indice()
                if let l = limites.first(where: { $0.mes == m }) { l.valor = sugestao } else { ctx.insert(LimiteMensal(mes: m, valor: sugestao)) }
                try? ctx.save()
                dismiss()
            }
            .buttonStyle(EstiloContorno())
        }
    }
}

struct Pontos: View {
    let total: Int
    let atual: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(Color.primary.opacity(i == atual ? 1 : 0.3))
                    .frame(width: i == atual ? 30 : 8, height: 8)
            }
        }
        .animation(.snappy, value: atual)
    }
}
