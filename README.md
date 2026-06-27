# Image-Filter-Applicator-FPGA

Aplicador de filtros de imagem em hardware para a plataforma **DE1-SoC (Cyclone V)**. O sistema captura imagens em tempo real com a câmera TRDB-D5M, processa cada pixel utilizando um coprocessador de convolução implementado em lógica programável e exibe o resultado em um monitor via VGA.

---

## Sumário

- [Visão Geral da Arquitetura](#visão-geral-da-arquitetura)
- [Filtros Disponíveis](#filtros-disponíveis)
- [Coprocessador Auxiliar](#coprocessador-auxiliar)
- [A IPU — Unidade de Processamento de Imagem](#a-ipu--unidade-de-processamento-de-imagem)
- [Interface HPS](#interface-hps)
- [Protocolo de Instrução](#protocolo-de-instrução)
- [Estrutura de Arquivos](#estrutura-de-arquivos)
- [Como Compilar e Executar](#como-compilar-e-executar)
- [Hardware Necessário](#hardware-necessário)

---

## Visão Geral da Arquitetura

O sistema é composto por quatro subsistemas principais que operam em conjunto:

```
┌─────────────────────────────────────────────────────────────┐
│                          FPGA (Cyclone V)                    │
│                                                              │
│  ┌──────────┐    ┌────────────┐    ┌─────────────────────┐  │
│  │ TRDB-D5M │───▶│  vgaMemory │◀──▶│   IPU + Coprocessor │  │
│  │  Camera  │    │  (RAM 512²)│    │   (Convolução/B2G)  │  │
│  └──────────┘    └────────────┘    └─────────────────────┘  │
│                        │                                     │
│                  ┌─────▼──────┐                              │
│                  │ vga_control│──▶ Monitor VGA               │
│                  └────────────┘                              │
│                        ▲                                     │
│          LW-AXI Bridge │                                     │
└───────────────────────-┼────────────────────────────────────-┘
                         │
              ┌──────────▼──────────┐
              │  HPS (ARM Cortex-A9)│
              │  send_instruction.c │
              └─────────────────────┘
```

**Fluxo de dados:**

1. A câmera TRDB-D5M captura frames e os armazena continuamente na `vgaMemory` em formato Bayer (GRBG).
2. O HPS envia uma instrução de filtro via ponte Lightweight AXI (PIO).
3. A IPU lê a imagem da memória linha por linha, alimenta o coprocessador com janelas de pixels e escreve de volta o resultado filtrado.
4. O controlador VGA lê a `vgaMemory` em paralelo e exibe o frame processado.

---

## Filtros Disponíveis

| Código | Nome                    | Kernel | Operação    |
|--------|-------------------------|--------|-------------|
| 0      | Identidade              | 3×3    | CONV        |
| 1      | Detecção de Borda Roberts | 2×2  | CONV_ROB    |
| 2      | Detecção de Borda Sobel | 3×3    | CONV_TRSP   |
| 3      | Detecção de Borda Prewitt | 3×3  | CONV_TRSP   |
| 4      | Sobel Expandido         | 5×5    | CONV_TRSP   |
| 5      | Laplace                 | 5×5    | CONV_TRSP   |
| 6      | Sharpen                 | 3×3    | CONV        |
| 7      | Conversão para Escala de Cinza | 3×3 | B2G    |

Os filtros que utilizam `CONV_TRSP` processam **duas matrizes simultâneas** (kernel original + transposto/rotacionado 45°) e somam os resultados — adequado para detectores de borda que operam em duas direções ortogonais.

---

## Coprocessador Auxiliar

Arquivo principal: [cooprocessorFiles/controle/convolution_coprocessor.v](cooprocessorFiles/controle/convolution_coprocessor.v)

### Banco de Registradores

O módulo `br` ([br.v](cooprocessorFiles/controle/br.v)) armazena duas matrizes de operandos internos (**matrix_A** e **matrix_B**, 200 bits cada = 25 elementos de 8 bits) e uma matriz de resultado (**matrix_C**). O HPS pode pré-carregar esses registradores via instrução antes de acionar a operação.

Quando a IPU está processando, os operandos externos (`external_matrix_A` / `external_matrix_B`) sobrepõem os registradores internos via multiplexador.

### Convolução (`conv_geratriz`)

A convolução é realizada em um pipeline de estágios:

1. **Estágio de multiplicação:** cada par de elementos da janela de pixel e do kernel é multiplicado em paralelo.
2. **Estágios de adição em árvore:** os produtos são somados em pares em estágios sucessivos até restar um único acumulador.
3. **Saturação do resultado:** o valor final é forçado ao intervalo `[0, 255]`. Se negativo, é tomado o valor absoluto; se maior que 255, é saturado em 255.

Para operações que exigem dois kernels (ex.: Sobel X e Y), o módulo executa **duas convoluções simultâneas** e retorna tanto os resultados individuais quanto a soma saturada em um único barramento de 24 bits.

### Bayer para Escala de Cinza (`bayer2grey`)

A câmera TRDB-D5M entrega os pixels no formato Bayer GRBG. O módulo `bayer2grey` recebe uma janela parcial da imagem e realiza:

1. **Demosaicing:** interpola os canais R, G e B vizinhos pela média dos pixels ao redor (bilinear).
2. **Conversão para luminância:** aplica os pesos ITU-R BT.709:

   ```
   Y = 0.2126·R + 0.7152·G + 0.0722·B
   ```

### Máquina de Estados do Coprocessador

O coprocessador possui três estados internos:

| Estado   | Descrição                                                     |
|----------|---------------------------------------------------------------|
| `FETCH`  | Aguarda `activate_instruction`. Ao receber, armazena a instrução e decide entre `MEMORY` ou `EXECUTE`. |
| `MEMORY` | Realiza leituras/escritas diretas no banco de registradores.  |
| `EXECUTE`| Aciona a unidade aritmética e aguarda o sinal `done`.         |

O sinal `wait_signal` fica alto enquanto o estado não é `FETCH`, sinalizando ao HPS que o coprocessador está ocupado.

### Decodificador de Instrução (`decoder`)

Arquivo: [cooprocessorFiles/controle/decoder.v](cooprocessorFiles/controle/decoder.v)

O campo de instrução de 32 bits é decodificado da seguinte forma:

| Bits    | Campo      | Descrição                               |
|---------|------------|-----------------------------------------|
| `[3:0]` | `opcode`   | Operação a executar                     |
| `[9:4]` | `location` | Endereço do elemento no banco (6 bits)  |
| `[11:10]`| `id`      | Identificador de matriz (A ou B)        |
| `[19:12]`| `data_hi` | Byte alto para escrita / argumento      |
| `[27:20]`| `data_lo` | Byte baixo para escrita                 |

---

## A IPU — Unidade de Processamento de Imagem

Implementada dentro de [cooprocessorFiles/controle/top.v](cooprocessorFiles/controle/top.v), a IPU é a unidade de controle central do pipeline de processamento. Ela coordena a leitura da imagem, o envio ao coprocessador e a escrita do resultado.

### Máquina de Estados da IPU

```
          ┌──────────┐
   reset  │          │ instrução PHOTO_CONV
 ─────────▶   IDLE   ├──────────────────────▶ INIT_IPU
          │          │◀──── fim da imagem ─────────────┐
          └──────────┘                                  │
                                                        │
  INIT_IPU ──▶ TEST ──▶ EXT_DELAY ──▶ READ_LINE        │
                 ▲                        │             │
                 │              ┌─────────┴──────────┐  │
                 │              │ h_count < 0x1FC?    │  │
                 └──── TEST ◀──-┘ sim: volta          │  │
                                │ não: NEW_LINE ──────┤  │
                                └─────────────────────┘  │
                                          │               │
                                    loader == 0?          │
                                    sim: SEND_INST        │
                                          │               │
                              SEND_INST ──▶ WAIT_PROC     │
                                               │          │
                                         conv_done?       │
                                         SAVE_RES ────────┘
```

| Estado       | Ação principal                                                               |
|--------------|------------------------------------------------------------------------------|
| `IDLE`       | Monitora a instrução do HPS; ao detectar `PHOTO_CONV`, transita para `INIT_IPU`. |
| `INIT_IPU`   | Inicializa ponteiros de linha/coluna e o contador `loader` (número de linhas do kernel). |
| `TEST` / `EXT_DELAY` | Ciclos de latência para estabilização do acesso à memória.          |
| `READ_LINE`  | Lê 4 bytes por ciclo da `vgaMemory` e os acumula nos line buffers. Itera por `h_count` de 0 a `0x1FC`. |
| `NEW_LINE`   | Decrementa `loader` e avança `v_count_buf` para a próxima linha da memória.  |
| `SEND_INST`  | Monta a instrução `{v_conv, h_conv, opcode}` e aciona o coprocessador.      |
| `WAIT_PROC`  | Aguarda o sinal `conv_write_done` do módulo `write_result`.                  |
| `SAVE_RES`   | Avança os ponteiros de convolução (coluna → linha → fim).                    |

### Line Buffers

Arquivo: [cooprocessorFiles/camera/line_buffers.v](cooprocessorFiles/camera/line_buffers.v)

Cinco buffers circulares de 4096 bits (512 pixels × 8 bits) mantêm as linhas da janela de convolução em memória. O tamanho da janela é configurável:

| `size` | Janela  | Buffers usados |
|--------|---------|----------------|
| `2'b00`| 2×2     | BUFFER0, BUFFER1 |
| `2'b01`| 3×3     | BUFFER0, BUFFER1, BUFFER2 |
| `2'b11`| 5×5     | BUFFER0 … BUFFER4 |

A cada novo pixel processado, a janela desliza horizontalmente; ao mudar de linha, os buffers são rotacionados.

### Escrita do Resultado (`write_result`)

Arquivo: [cooprocessorFiles/controle/write_result.v](cooprocessorFiles/controle/write_result.v)

Como a `vgaMemory` armazena 4 pixels por palavra de 32 bits, o módulo `write_result` realiza uma operação **read-modify-write**: lê a palavra atual, substitui apenas o byte correspondente ao pixel calculado (usando o offset de 2 bits do endereço) e escreve de volta.

---

## Interface HPS

Arquivo: [HPS_interface/send_instruction.c](HPS_interface/send_instruction.c)

O programa C roda no processador ARM do HPS e se comunica com a lógica FPGA via mapeamento de memória física (`/dev/mem`).

### Mapa de Memória

| Endereço base    | Offset | Direção   | Função                          |
|------------------|--------|-----------|---------------------------------|
| `0xFF200000`     | `0x00` | HPS → FPGA | PIO de comando (`pio_out`)     |
| `0xFF200000`     | `0x10` | FPGA → HPS | PIO de status (`pio_in`)       |

### Menu Interativo

Ao executar, o programa exibe um menu no terminal serial:

```
===What wanna do?===
0 -  Identity
1 -  ED Roberts
2 -  ED Sobel
3 -  ED Prewitt
4 -  ED Exp. Sobel
5 -  ED Laplace
6 -  Sharpen
7 -  Convert to Grayscale
8 -  Read Image
===Any other integer to close program===
```

As opções 0–7 montam a instrução `PHOTO_CONV` com o código do filtro e escrevem no PIO. A opção 8 transfere o frame bruto da FPGA para o HPS e salva três arquivos em `data/`:

| Arquivo           | Conteúdo                     |
|-------------------|------------------------------|
| `raw.png`         | Frame bruto em Bayer (8-bit) |
| `outputRGB.png`   | Frame demosaicado (RGB 24-bit)|
| `outputGS.png`    | Frame em escala de cinza     |

A transferência lê 65536 palavras de 32 bits (256×256 pixels × 4 bytes) via iteração com PIO, sem DMA.

### Demosaicing no HPS (`bayer_grbg_to_rgb`)

A função implementa interpolação bilinear para o padrão GRBG com tratamento de todos os quatro tipos de pixel da grade Bayer (G em linha par, R em linha par, B em linha ímpar, G em linha ímpar). A conversão para luminância usa os pesos sRGB da W3C.

---

## Protocolo de Instrução

A instrução de 32 bits enviada pelo HPS ao FPGA tem o seguinte formato para a operação de filtro (`PHOTO_CONV = 0xE`):

```
 31        20 19    8  7    4  3    0
┌────────────┬────────┬──────┬──────┐
│  (não usado)│  addr  │ code │ opcode│
└────────────┴────────┴──────┴──────┘
                        ↑       ↑
                  código do   0xE (PHOTO_CONV)
                   filtro     ou 0xF (READ_IMAGE)
```

Para `READ_IMAGE` (`opcode = 0xF`), os bits `[19:4]` contêm o endereço do pixel a ser lido da memória de vídeo.

A função `getInstruction(num)` no HPS monta esse valor:

```c
int getInstruction(int num) {
    return 14 | (num << 4);   // opcode=0xE, code=num
}
```

---

## Estrutura de Arquivos

```
.
├── cooprocessorFiles/
│   ├── controle/
│   │   ├── top.v                  — Módulo top-level; integra todos os subsistemas
│   │   ├── convolution_coprocessor.v — Coprocessador de convolução/B2G
│   │   ├── decoder.v              — Decodificador de instrução (32 bits → campos)
│   │   ├── decode_ipu.v           — Tabela de kernels por código de filtro
│   │   ├── br.v                   — Banco de registradores de matrizes
│   │   └── write_result.v         — Escrita byte-a-byte na vgaMemory
│   ├── camera/
│   │   ├── DE2_D5M.v              — Interface com câmera TRDB-D5M (Terasic)
│   │   ├── CCD_Capture.v          — Captura de pixels CCD
│   │   ├── I2C_CCD_Config.v       — Configuração da câmera via I2C
│   │   ├── I2C_Controller.v       — Controlador I2C genérico
│   │   ├── line_buffers.v         — Buffers circulares de linha para janela de convolução
│   │   ├── Reset_Delay.v          — Circuito de atraso de reset
│   │   └── SEG7_LUT*.v            — Decodificadores para display de 7 segmentos
│   ├── ip/
│   │   ├── debounce/              — Debounce de botões
│   │   ├── edge_detect/           — Detector de borda de sinal digital
│   │   └── altsource_probe/       — Reset controlado pelo HPS
│   ├── soc_system.qsys            — Projeto Platform Designer (Qsys)
│   ├── soc_system.qpf / .qsf      — Projeto e atribuições de pinos Quartus
│   └── output_files/soc_system.sof — Bitstream gerado
│
├── HPS_interface/
│   ├── send_instruction.c         — Aplicação C para envio de filtros pelo HPS
│   ├── makefile                   — Compilação com gcc
│   ├── lib/
│   │   ├── hps.h                  — Mapa de endereços dos periféricos (gerado pelo Qsys)
│   │   ├── stb_image.h            — Biblioteca single-header para leitura de imagens
│   │   └── stb_image_write.h      — Biblioteca single-header para escrita de imagens
│   └── data/
│       └── dummy.txt              — Placeholder para os PNGs gerados
│
└── README.md
```

---

## Como Compilar e Executar

### 1. Síntese do projeto FPGA

1. Abra o projeto `cooprocessorFiles/soc_system.qpf` no **Intel Quartus Prime**.
2. Execute **Processing → Start Compilation** (ou `Ctrl+L`).
3. Grave o bitstream em `output_files/soc_system.sof` na placa via **Programmer**.

### 2. Configuração do Platform Designer

O arquivo `soc_system.qsys` define a interconexão HPS↔FPGA. Se for necessário regenerar os arquivos de síntese:

```
Tools → Platform Designer → Generate HDL
```

### 3. Compilação da interface HPS

No terminal Linux da DE1-SoC (conectado via serial ou SSH):

```bash
cd HPS_interface
make run
```

O `makefile` compila e executa o binário em um único passo:

```makefile
gcc -o FPGA_interface send_instruction.c -lm -std=c99
./FPGA_interface
```

> **Atenção:** o acesso a `/dev/mem` requer privilégios de root. Execute com `sudo` se necessário.

### 4. Uso

Após iniciar o programa, escolha o filtro desejado pelo número no menu. O FPGA processa o frame atual e exibe o resultado no monitor VGA em seguida. Para capturar a imagem atual como arquivo PNG, use a opção **8**.

---

## Hardware Necessário

| Componente          | Descrição                                    |
|---------------------|----------------------------------------------|
| DE1-SoC             | FPGA Cyclone V com HPS ARM Cortex-A9         |
| TRDB-D5M            | Câmera CCD 5MP Terasic (conectada no GPIO)   |
| Monitor VGA         | Resolução mínima 640×480                     |
| Terminal serial/SSH | Para acesso ao HPS Linux                     |
