# Horizon Moto GPS

Aplicativo Android em **Flutter/Dart** pensado para motociclistas (tema **Forza Horizon + KTM Ready to Race**): transforma o mapa da cidade e das estradas em áreas exploráveis onde **todas as ruas inéditas aparecem em cinza escuro** e **todas as estradas onde você já pilotou acendem em Laranja Neon (`#FF6600`)**.

Além da descoberta progressiva de mapa, o aplicativo funciona como **GPS completo com busca de endereços e comércios**, **alerta de radares**, **gravador de rolês** e **checkpoints fotográficos**.

---

## Principais funcionalidades

1. **Descoberta de Estradas estilo Forza Horizon**
   - Grade espacial em SQLite (`~25m` por setor) com interpolação contínua de segmentos GPS para evitar falhas mesmo em velocidades mais altas.
   - Estradas já percorridas ficam iluminadas em **Laranja Neon** permanentemente no mapa escuro (*CartoDB Dark Matter @2x*).
   - Contador em tempo real de **quilômetros descobertos** e **setores desbloqueados**.
   - **Modo Simulação Demo (BH)**: permite simular um trajeto pela região da Praça da Liberdade / Afonso Pena dentro de casa para testar o desbloqueio das vias e alertas de radar antes de sair com a moto.

2. **Navegação GPS, Busca de Comércios & Métrica `% Inédito`**
   - Busca por qualquer rua, bairro ou estabelecimento via OpenStreetMap Nominatim.
   - Atalhos rápidos em 1 toque ao redor da moto via Overpass API: **Postos**, **Oficinas**, **Cafés e Lanches**.
   - Roteamento rua a rua via **OSRM** traçado em **Ciano Horizon (`#00E5FF`)**, exibindo distância, tempo estimado, próxima manobra e **porcentagem de estradas inéditas na rota**.
   - Segurar o dedo (*Long-Press*) em qualquer ponto do mapa permite traçar rota ou marcar um alerta na hora.

3. **Radares de Velocidade & Alerta de Proximidade**
   - Carrega radares fixos cadastrados no OpenStreetMap (`highway=speed_camera`) em um raio de 6 km.
   - Permite salvar seus próprios radares/alertas (`40`, `50`, `60`, `70`, `80`, `100`, `110 km/h`) em SQLite.
   - Banner vermelho de alerta automático sempre que a moto se aproximar a menos de **350 metros** de um radar.

4. **Gravador de Rolês + Diário + Checkpoints Fotográficos**
   - Painel inferior inspirado no TFT da KTM 390 Duke com velocímetro digital em tempo real, cronômetro e distância da sessão (`+km inéditos`).
   - Botão para tirar foto e fixar um **Checkpoint** com localização exata no mapa.
   - Tela **Diário de Rolês** listando odômetro total do app, rolês salvos (toque para focar o trajeto no mapa), galeria de checkpoints e lista de radares próprios.

---

## Instalação direta no Android (APK)

O build é compilado automaticamente via **GitHub Actions** (`flutter analyze`, `flutter test` e `flutter build apk --release`):

- Download direto: [app-release.apk (v1.0.0)](https://github.com/hipolitopeedro/horizon-moto-gps/releases/latest/download/app-release.apk)

---

## Stack técnica

| Biblioteca | Finalidade |
|---|---|
| `flutter_map` + `latlong2` | Renderização do mapa interativo, polilinhas neon e marcadores |
| `geolocator` | Stream GPS de alta precisão e velocidade em tempo real |
| `sqflite` + `path` | Banco SQLite local para setores explorados, rolês, radares e checkpoints |
| `http` | Integração sem API key paga com Nominatim, Overpass API e OSRM |
| `image_picker` + `path_provider` | Captura e salvamento local de fotos de checkpoints |
| `wakelock_plus` | Mantém a tela do celular acesa durante o rolê |
| `intl` | Formatação de data e hora |
