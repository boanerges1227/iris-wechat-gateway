ARG IMAGE=intersystems/irishealth-community:2026.2
FROM ${IMAGE}

WORKDIR /home/irisowner/dev

ARG NAMESPACE="WECHAT"

ENV IRISUSERNAME "_SYSTEM"
ENV IRISPASSWORD "SYS"
ENV IRISNAMESPACE $NAMESPACE
ENV PATH "/usr/irissys/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/irisowner/bin"

COPY merge.cpf /home/irisowner/dev/merge.cpf

RUN --mount=type=bind,src=.,dst=. \
    iris start IRIS && \
    iris merge IRIS /home/irisowner/dev/merge.cpf && \
    iris session IRIS < iris.script > /tmp/wechat-build.log 2>&1 && \
    cat /tmp/wechat-build.log && \
    grep -Eq '^WECHAT_BUILD_OK=1[[:space:]]*$' /tmp/wechat-build.log && \
    ! grep -Eq 'ERROR #|<[A-Z][A-Z ]+>' /tmp/wechat-build.log && \
    iris stop IRIS quietly
