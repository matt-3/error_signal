# Como contribuir

[English](CONTRIBUTING.md) | Português

Obrigado pela ajuda. Relatos de bug, correções, melhorias e traduções são todos
bem-vindos.

## Relatando um bug

Abra uma issue com:

- as versões do Ruby e do Rails, e o cache store que a sua app usa;
- o que você fez, o que esperava e o que aconteceu;
- as linhas `[ErrorSignal]` do seu log, se houver;
- a saída do `bin/rails error_signal:check`.

Deixe de fora da issue URLs de webhook reais, tokens e dados pessoais. Se o bug for um
vazamento (um dado pessoal ou um segredo chegando ao Discord), descreva o formato do dado
(por exemplo "um telefone escrito como `11 9 1234 5678`") em vez do valor real.

## Antes de uma mudança maior

Abra uma issue antes para qualquer coisa além de uma correção pequena: uma dependência
nova, uma configuração nova, uma mudança no que é postado ou no formato da mensagem. A
gem foi feita para continuar pequena e segura de colocar em qualquer app Rails, então
vale combinar o caminho antes de escrever o código.

## Fazendo uma mudança

1. Faça um fork do repositório e crie uma branch.
2. Instale as dependências e rode as verificações:

   ```bash
   bundle install
   bundle exec rake test
   bundle exec rubocop
   ```

   Para rodar uma versão do Rails da matriz do CI, aponte o Bundler para o gemfile dela:

   ```bash
   BUNDLE_GEMFILE=gemfiles/rails_7_1.gemfile bundle install
   BUNDLE_GEMFILE=gemfiles/rails_7_1.gemfile bundle exec rake test
   ```

3. Acrescente um teste para a mudança. Os testes rodam sobre uma app Rails pequena
   (`test/test_helper.rb`) e nunca tocam a rede: o `capturing_posts` guarda os payloads
   em vez de postá-los, e o `test/capture_test.rb` roda processos reais do
   `rails runner` e do rake contra um webhook local.
4. Mantenha as garantias: o Error Signal nunca levanta erro, nunca segura a requisição, não
   acrescenta dependência em tempo de execução, custa poucas operações de cache por erro e
   nunca deixa sair texto sem sanitizar. Uma mudança que enfraqueça alguma delas precisa
   de um motivo muito bom no pull request.
5. Atualize os dois READMEs (`README.md` e `README.pt-BR.md`) quando o comportamento ou
   a configuração mudar, e acrescente uma linha no `CHANGELOG.md`. Se o texto de uma
   mensagem mudar, atualize os payloads no `docs/assets/make_images.py` e rode-o
   (`python3 docs/assets/make_images.py`): as imagens do README mostram as mensagens reais.
6. Abra o pull request explicando o que mudou e por quê.

O CI roda os testes em cada par de Ruby 3.4 e 4.0 com Rails 7.1, 7.2, 8.0 e 8.1, e o
RuboCop e o `gem build` uma vez.

## Traduzindo as mensagens

1. Acrescente o idioma em `MESSAGES`, no `lib/error_signal/messages.rb`, com
   todas as chaves e os mesmos `%{marcadores}` (o teste `every locale defines every message
   key, with the same placeholders` confere).
2. Ensine o `ErrorSignal::Config.locale` a reconhecer o novo valor de
   `ERROR_SIGNAL_LOCALE`.
3. Acrescente um teste que monte um alerta e um relatório no novo idioma, e cite o idioma
   na linha da `ERROR_SIGNAL_LOCALE` dos dois READMEs.

## Melhorando o sanitizador embutido

As regras globais ficam em `lib/error_signal/sanitizer.rb`, e cada pacote por
país num arquivo próprio em `lib/error_signal/pii/` (registrado no `pii.rb`).
Para cada regra nova, acrescente no `test/sanitizer_test.rb` exemplos que ela precisa
filtrar e exemplos que ela precisa deixar como estão, e confira que `does not mangle
backtraces, class names, dates, versions, ids, prices or prose` continua passando: uma
regra que come datas, IDs ou nomes de classe deixa a mensagem inútil. Prefira um dígito
verificador (Luhn, módulo 97, módulo 11) a só o formato sempre que o documento tiver um, e
ponha documentos nacionais num pacote, não na camada global.

Decida pelo que a regra troca o trecho. Dado pessoal recebe uma máscara parcial
(`Sanitizer::Mask.last` para os 4 últimos, `Sanitizer::Mask.keep` para as posições que
distinguem um registro do outro sem ser um sufixo fixo, como a filial do CNPJ), e o
formato esperado vai no `test/mask_test.rb`. Um segredo (senha, token, chave) recebe o
`Sanitizer::FILTERED` inteiro e nunca é mascarado em parte.

## Licença

Ao contribuir, você concorda que as suas contribuições são distribuídas sob a
[Licença MIT](LICENSE).
