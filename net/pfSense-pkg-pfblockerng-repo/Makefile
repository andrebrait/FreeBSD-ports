PORTNAME=	pfSense-pkg-pfblockerng-repo
PORTVERSION=	4.0.0.alpha.2
CATEGORIES=	net

MAINTAINER=	coreteam@pfsense.org
COMMENT=	pfBlockerNG self-hosted pkg repository bootstrap

LICENSE=	APACHE20

NO_BUILD=	yes
NO_ARCH=	yes

USE_GITHUB=	yes
GH_ACCOUNT=	pfBlockerNG
GH_PROJECT=	pfBlockerNG
GH_TAGNAME=	v${PORTVERSION}
DIST_SUBDIR=	${PORTNAME}

# GitHub extracts to <project>-<version>/; the detection helper lives under
# scripts/lib/ in the full repo checkout (not under src/).
WRKSRC=		${WRKDIR}/${GH_PROJECT}-${PORTVERSION}

# Install path for the on-box variant-detection helper.
# pkg-post-install.in sources this to compute <varver>/<arch>.
DETECT_HELPER_DIR=	${PREFIX}/share/${PORTNAME}
DETECT_HELPER=		${DETECT_HELPER_DIR}/detect_variant.sh

SUB_FILES=	pkg-post-install pkg-post-deinstall
SUB_LIST=	PORTNAME=${PORTNAME} \
		DETECT_HELPER=${DETECT_HELPER}

do-install:
	${MKDIR} ${STAGEDIR}${DETECT_HELPER_DIR}
	${INSTALL_SCRIPT} ${WRKSRC}/scripts/lib/detect_variant.sh \
		${STAGEDIR}${DETECT_HELPER_DIR}/detect_variant.sh

.include <bsd.port.mk>
