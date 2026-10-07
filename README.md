# Jabba-Terminal

Terminale di scambio P2P su Robinhood Chain, contratto **Jabba**.

Exchange P2P maker-contro-maker su Robinhood Chain (chain ID 4663), regolato interamente da Permit2.
Ogni scambio incrocia due ordini firmati, tutto-o-niente. Nessuna custodia, nessun owner, nessun oracolo;
l'unico storage persistente è la fee in ETH (iniziale 0,00005 ETH per match).

La specifica normativa è in [`docs/SPEC.md`](docs/SPEC.md) (v2.4).

## Struttura

```
src/Jabba.sol               contratto: matchOrders, post, setFee
test/Jabba.t.sol            test unitari, di perimetro e fuzz (invarianti I1–I8)
test/utils/Base.sol         harness: Permit2 reale, firme EIP-712 indipendenti dal contratto
test/utils/Mocks.sol        token di test: conforme, fee-on-transfer, pausa/blocklist, malevolo, rientrante
script/Deploy.s.sol         deploy CREATE2
docs/SPEC.md                specifica v2.4
docs/FORMAL.md              verifica formale I1–I8: Halmos, Certora, mutation testing
test/formal/                check Halmos e modello di Permit2
certora/                    regole Certora (Prover open source, in locale)
mutation/                   mutazioni mirate e Gambit, risultati
web/index.html              terminale (demo con chain simulata)
.github/workflows/test.yml  CI: build, test e Halmos
```

## Setup

Richiede [Foundry](https://getfoundry.sh).

```sh
git clone --recurse-submodules https://github.com/arabafenice599rae/Jabba-Terminal
cd Jabba-Terminal
forge build
forge test
```

`lib/forge-std` e `lib/permit2` sono submodule; se il repo è già clonato senza, `git submodule update --init --recursive`.
Le remapping sono in `foundry.toml`.

## Contratto

| Funzione | Cosa fa |
|---|---|
| `matchOrders(Side a, Side b)` payable | Esegue per intero due ordini opposti; `msg.value` deve essere esattamente `fee` |
| `post(Side s)` | Pubblica un ordine come evento `OrderPosted`; nessuno storage |
| `setFee(uint256)` | Solo `TREASURY`; qualsiasi valore, zero compreso |
| `orderHash(Side)` / `permitWitnessStructHash(Side)` | View per terminale e indexer |

`match` è una parola riservata in Solidity: la funzione della specifica si chiama `matchOrders`.

Ordine = firma Permit2 `PermitWitnessTransferFrom` con `spender = Jabba` e witness
`Order(address buyToken,uint256 buyAmount)`. Il prezzo è il rapporto tra `sellAmount` e `buyAmount`.

## Test

```sh
forge test              # tutti
forge test --mc Fuzz    # solo fuzz
forge test -vvvv --mt test_match_exact
```

Coperti: match esatto e con surplus, replay, cancellazione, scadenza, witness manomesso, firma compatta
EIP-2098, submitter terzo, fee sbagliata e cambio fee in volo, tesoriere che rifiuta ETH, `post` senza
scritture, coerenza degli hash con Permit2, token fee-on-transfer, token in pausa e maker in blocklist
(nessun nonce consumato), rientro bloccato, token malevolo fuori perimetro, fuzz di conservazione.

## Deploy

```sh
export TREASURY=0x...        # multisig
export FEE_WEI=50000000000000
forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --verify --private-key $PK
```

Prima del deploy in produzione eseguire i passi 8–9 del piano di verifica (§12 della specifica):
verifica formale e fork test su 4663 con stock token reali.

## Terminale

`web/index.html` è un file statico unico: si apre nel browser del wallet o si pubblica su GitHub Pages.
La versione attuale è una demo: firme EIP-712 reali (wallet collegato via EIP-6963 o account demo),
chain simulata. Il collegamento al contratto deployato (log `OrderPosted`, `eth_call`, invio di `matchOrders`)
è il passo successivo.
