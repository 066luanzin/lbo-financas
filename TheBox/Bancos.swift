import SwiftUI
import SwiftData

/// Home: quanto tem em cada banco (a soma é o "Na conta hoje")
struct CartaoBancos: View {
    let fin: Financas
    var abrir: () -> Void

    var body: some View {
        let mes = Mes.indice()
        let bancos = fin.bancos().map { ItemValor(nome: $0.nome, valor: fin.saldoCarteira($0.nome, ate: mes)) }
            .filter { abs($0.valor) >= 0.01 }
        if !bancos.isEmpty {
            Button(action: abrir) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SEUS BANCOS").font(.system(size: 12, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                    ForEach(bancos) { b in
                        HStack {
                            Text(b.nome).font(.system(size: 15))
                            Spacer()
                            Text(b.valor.moeda).font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(b.valor < 0 ? Color.red : Color.primary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cartao(18)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Ver detalhes: saldo de cada banco + "sem banco definido"
struct SecaoBancos: View {
    let fin: Financas
    @State private var ajustar = false

    var body: some View {
        let mes = Mes.indice()
        let bancos = fin.bancos().map { ItemValor(nome: $0.nome, valor: fin.saldoCarteira($0.nome, ate: mes)) }
        let semBanco = fin.saldo(em: mes) - bancos.reduce(0) { $0 + $1.valor }
        VStack(alignment: .leading, spacing: 10) {
            Text("Quanto tem em cada banco").font(.system(size: 15, weight: .semibold)).padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(bancos) { b in
                    LinhaStat(titulo: b.nome, valor: b.valor.moeda)
                    Divider().overlay(Color.borda)
                }
                if abs(semBanco) >= 0.01 {
                    LinhaStat(titulo: "Sem banco definido", valor: semBanco.moeda)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(Color.cartao2.opacity(0.45), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Button { ajustar = true } label: {
                Label("Ajustar cada banco igual ao app dele", systemImage: "building.columns")
            }
            .buttonStyle(EstiloContorno())
            Text("Abra o app de cada banco e digite o saldo. O total fica igual à soma e o \"sem banco definido\" some.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $ajustar) { AjusteBancosSheet(fin: fin) }
    }
}

struct AjusteBancosSheet: View {
    let fin: Financas
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx
    @State private var textos: [String: String] = [:]

    var body: some View {
        let bancos = fin.bancos()
        let soma = bancos.reduce(0) { $0 + (lerValor(textos[$1.nome] ?? "") ?? 0) }
        VStack(alignment: .leading, spacing: 14) {
            Text("Saldo de cada banco agora").font(.system(size: 21, weight: .bold))
            Text("Olhe no app de cada um e digite o valor. Banco zerado, deixe 0,00.")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(bancos) { b in
                HStack(spacing: 10) {
                    Text(b.nome).font(.system(size: 15))
                    Spacer()
                    Text(Moeda.atual.simbolo).foregroundStyle(.secondary)
                    TextField("0,00", text: campo(b.nome))
                        .mascaraDinheiro(campo(b.nome))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                }
                .campo()
            }
            HStack {
                Text("Total").fontWeight(.semibold)
                Spacer()
                Text(soma.moeda).fontWeight(.bold)
            }
            Button("Salvar") {
                var reais: [String: Double] = [:]
                for b in bancos { reais[b.nome] = lerValor(textos[b.nome] ?? "") ?? 0 }
                Ajuste.igualarBancos(reais, ctx: ctx)
                Notificacoes.agora("Bancos ajustados", "Total: \(soma.moeda), igual à soma dos seus bancos.")
                dismiss()
            }
            .buttonStyle(EstiloPrincipal())
        }
        .padding(28)
        .folha([.large])
        .onAppear {
            let mes = Mes.indice()
            for b in bancos where textos[b.nome] == nil {
                textos[b.nome] = textoDinheiro(max(0, fin.saldoCarteira(b.nome, ate: mes)))
            }
        }
    }

    private func campo(_ nome: String) -> Binding<String> {
        Binding(get: { textos[nome] ?? "" }, set: { textos[nome] = $0 })
    }
}
