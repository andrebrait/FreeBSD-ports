PORTNAME=	json-fortran
DISTVERSION=	8.3.0-8
DISTVERSIONSUFFIX=	-gd296de8a4
CATEGORIES=	devel

MAINTAINER=	yuri@FreeBSD.org
COMMENT=	Modern Fortran JSON API
WWW=		https://github.com/jacobwilliams/json-fortran/

LICENSE=	BSD3CLAUSE
LICENSE_FILE=	${WRKSRC}/LICENSE

USES=		cmake:testing fortran

USE_GITHUB=	yes
GH_ACCOUNT=	jacobwilliams

CMAKE_ON=	USE_GNU_INSTALL_CONVENTION

# all tests fail, see https://github.com/jacobwilliams/json-fortran/issues/539

.include <bsd.port.mk>
