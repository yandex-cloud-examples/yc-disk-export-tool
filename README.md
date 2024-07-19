
# Yandex Cloud Disk Export Tool

## Оглавление
* [Обзор](#overview)
* [Описание процесса](#description)
* [Права доступа и роли](#roles)
* [Подготовка инструмента к работе](#install)
* [Порядок использования](#userguide)
* [Примеры использования](#examples)
  * [Инициализация](#example-init)
  * [Экспорт диска ВМ](#example-disk)
  * [Экспорт образа диска](#example-image)
* [*Проверка созданного образа (необязательно)*](#test)
* [*Подключение к Export Helper ВМ по SSH (при необходимости)*](#diag)


## Обзор <a id="overview"/></a>

Инструмент может:
* Экспортировать загрузочный [диск ВМ](https://yandex.cloud/ru/docs/compute/concepts/disk) в [Yandex Object Storage](https://yandex.cloud/ru/docs/storage).
* Экспортировать [образ ВМ](https://yandex.cloud/ru/docs/compute/concepts/image) в [Yandex Object Storage](https://yandex.cloud/ru/docs/storage).

В результате работы инструмента в указанном [bucket](https://yandex.cloud/ru/docs/storage/concepts/bucket) S3-хранилища будет создан файл с образом диска в формате [qcow2](https://ru.wikipedia.org/wiki/Qcow2).


## Описание процесса <a id="description"/></a>

Экспорт работает следующим образом:

1. Создаётся диск для ВМ из [снимка диска](https://yandex.cloud/ru/docs/compute/concepts/snapshot) или из [образа диска](https://yandex.cloud/ru/docs/compute/concepts/image) (в зависимости от выбранного режима работы инструмента).

2. В каталоге заданном при инициализации создаётся `Export Helper ВМ` к которой подключается диск, созданный на первом этапе.

3. В ВМ выполнется чтение данных с дополнительного диска и создание его образа с помощью инструмента [qemu-img](https://www.qemu.org/docs/master/tools/qemu-img.html).

4. Полученный образ диска загружается в [Yandex Object Storage](https://yandex.cloud/ru/docs/storage) с помощью инструмента [Amazon CLI version 2](https://docs.amazonaws.cn/en_us/cli/latest/userguide/getting-started-version.html).

5. После выполнения всех вышеописанных действий ВМ самоликвидируется с помощью [API вызова](https://yandex.cloud/ru/docs/compute/api-ref/Instance/delete).

По мере выполнения задач в рамках процесса инструмент пишет диагностические сообщения в [группу Default](https://yandex.cloud/ru/docs/logging/concepts/log-group) сервиса [Cloud Logging](https://yandex.cloud/ru/docs/logging/). 


## Права доступа и роли <a id="roles"/></a>

Для развёртывания инструмента и его запуска требуется определенный набор [полномочий (ролей)](https://yandex.cloud/ru/docs/iam/roles-reference) в Yandex Cloud.

При подготовке инструмента к работе, в указанном при инициализации каталоге создаётся [Service Account](https://yandex.cloud/ru/docs/iam/concepts/users/service-accounts) со следуюшим набором ролей:
* [compute.editor](https://yandex.cloud/ru/docs/iam/roles-reference#compute-editor) - для удаления `Export Helper ВМ` после завершения экспорта.
* [storage.uploader](https://yandex.cloud/ru/docs/iam/roles-reference#storage-uploader) - для загрузки созданного образа диска в [Object Storage](https://yandex.cloud/ru/docs/storage/).
* [lockbox.payloadViewer](https://yandex.cloud/ru/docs/iam/roles-reference#lockbox-payloadViewer) - для получения секретов для работы с [Object Storage](https://yandex.cloud/ru/docs/storage/).
* [logging.writer](https://yandex.cloud/ru/docs/iam/roles-reference#logging-writer) - для логирования хода процесса экспорта в [Cloud Logging](https://yandex.cloud/ru/docs/logging/).

Далее этот SA привязывается к `Export Helper ВМ`.


## Подготовка инструмента к работе <a id="install"/></a>

Для работы инструмента необходимо использовать операционную систему Linux или MacOS. 

Работа инструмента в среде [Windows Subsystem for Linux (WSL)](https://learn.microsoft.com/en-us/windows/wsl/) не гарантируется!

Перед использованием инструмент нужно развернуть и подготовить к работе (выполнить инциализацию). Для этого необходимо:

1. Убедиться, что все необходимые инструменты установлены и настроены:
* `yc CLI` - [установлен](https://yandex.cloud/ru/docs/cli/operations/install-cli) и [настроен](https://yandex.cloud/ru/docs/cli/operations/profile/profile-create#create).
* `jq` - [установлен](https://jqlang.github.io/jq/download/).


2. Загрузить решение из репозитория на [github.com](https://github.com/yandex-cloud-examples/yc-disk-export-tool):
```bash
git clone https://github.com/yandex-cloud-examples/yc-disk-export-tool.git
```

3. Перейти в папку с инструментом
```bash
cd yc-disk-export-tool.git
```

4. Запустить инициализацию инструмента

Инициализация выполняется только один раз, выполнять его перед каждым запуском инструмента не нужно!

```bash
./init.sh <folder-id> <bucket-name> <sa-name> <subnet-name> <config-file>
```

Для инциализации нужно указать следующие обязательные параметры:
* [folder-id](https://yandex.cloud/ru/docs/resource-manager/concepts/resources-hierarchy#folder) - идентификатор каталога облачных ресурсов в Yandex Cloud где будут развернуты ресурсы, необходимые для работы инструмента. У пользователя, запускающего процесс инициализации, должны быть права администратора в данном каталоге.
* [bucket-name](https://yandex.cloud/ru/docs/storage/concepts/bucket) - название bucket (*имя папки*) в Yandex Object Storage куда будут загружаться резервные копии.
* [sa-name](https://yandex.cloud/ru/docs/iam/concepts/users/service-accounts) - имя сервисной учетной записи, которая будет привязана к `Export Helper ВМ` от имени которой будут выполняться операции по работе с S3 bucket.
* [subnet](https://yandex.cloud/ru/docs/overview/concepts/geo-scope) - имя подсети к которой будет подключаться `Export Helper ВМ`.
* `config-file` - имя файла конфигурации (полный путь, если нужно) в формате [JSON](https://www.json.org/json-ru.html), в который будут записаны все нужные для работы инструмента параметры. Путь к файлу конфигурации нужно будет указывать при запуске инструмента.


## Порядок использования <a id="userguide"/></a>

Перед началом использования, убедитесь, что [инструмент подготовлен к работе](#install).

```bash
./yc-disk-export.sh <source-type> <folder-id> <source-name> <config-file>
```

У пользователя, запускающего инструмент, должны быть права на чтение в соответствующем каталоге, для ресурса который будет экспортироваться.

При запуске инструмента необходимо указать следующие обязательные параметры:
* `source-type` - тип источника данных. Определяет режим работы инструмента. Может принимать значения: `disk` или `image` в зависимости от типа ресурса для которого будет выполняться резервное копирование.
* `folder-id` - [идентификатор каталога]((https://yandex.cloud/ru/docs/resource-manager/concepts/resources-hierarchy#folder)) облачных ресурсов в Yandex Cloud где находится источник данных.
* `source-name` - имя ресурса источника данных в указанном каталоге облачных ресурсов:
  - для источника типа `disk` - это `название ВМ`
  - для источника типа `image` - это `название образа`
* `config-file` - путь к файлу конфигурации, созданный при инициализации инструмента.


## Примеры использования <a id="examples"/></a>

### Инициализация <a id="example-init"/></a>
```bash
./init.sh b1g22jx2133dpa3yvxc3 my-s3-bucket disk-export-sa subnet-a ./disk-export.cfg
```

### Экспорт диска ВМ <a id="example-disk"/></a>
```bash
./yc-disk-export.sh disk b1g22jx2133dpa3yvxc3 my-vm ./disk-export.cfg
```

### Экспорт образа диска <a id="example-image"/></a>
```bash
./yc-disk-export.sh image b1g22jx2133dpa3yvxc3 win-image ./disk-export.cfg
```


## *Проверка созданного образа (необязательно)* <a id="test"/></a>

При необходимости можно проверить созданный образ на работоспособность, развернув ВМ из этого образа локально.

Ниже представлен пример запуска ВМ из образа на компьютере с ОС `MacOS` и инструментом [qemu](https://www.qemu.org/):

```bash
qemu-system-x86_64 -name my-test-vm \
  -machine accel=hvf,type=q35 -cpu host -m 4G -nographic \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -drive if=virtio,format=qcow2,file=my-vm.qcow2
```

После запуска ВМ к ней можно будет подключиться как через консоль, так и по протоколу SSH - `ssh -p 2222 admin-user@localhost`.


## Подключение к Export Helper ВМ по SSH <a id="diag"/></a>

В случае возникновения нестандартных ситуаций может потребоваться доступ к `Export Helper ВМ` по протоколу SSH. По умолчанию доступ к ВМ по протоколу SSH отключен.

Для организации доступа к ВМ по протоколу SSH, перед запуском иструмента необходимо:
1. Раскомментировать часть `users:` в файле шаблона создания ВМ - [vm-init.tpl](./vm-init.tpl) (строки 7-12).
2. Задать имя пользователя и SSH-ключ для доступа через переменные окружения, как показано в примере ниже.

```bash
# Задать переменные окружения для доступа к Export Helper VM по SSH
export USER_NAME=admin
export USER_SSH_KEY=$(cat ~/.ssh/id_ed25519.pub)

# Запустить инструмент
./yc-disk-export.sh disk b1g22jx2133dpa3yvxc3 my-vm ./disk-export.cfg

# Подключиться к Export Helper VM
ssh admin@<helper-vm-public-ip>
```
